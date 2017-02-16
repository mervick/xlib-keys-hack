-- Author: Viacheslav Lotsmanov
-- License: GPLv3 https://raw.githubusercontent.com/unclechu/xlib-keys-hack/master/LICENSE

{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoMonomorphismRestriction #-}

module Process.Keyboard
  ( handleKeyboard
  ) where

import qualified "base" GHC.IO.Handle as IOHandle
import qualified "linux-evdev" System.Linux.Input.Event as EvdevEvent

import "transformers" Control.Monad.Trans.Class (lift)
import "base" Control.Monad (when, unless, forM_, forever)
import "lens" Control.Lens ((.~), (%~), (^.), set, over, view, Lens', mapped)
import "base" Control.Concurrent.MVar (MVar, modifyMVar_)
import "base" Control.Concurrent.Chan (Chan)
import "transformers" Control.Monad.IO.Class (liftIO)
import "transformers" Control.Monad.Trans.State (execStateT)
import "either" Control.Monad.Trans.Either (EitherT, runEitherT, left, right)

import "base" Data.Maybe (fromJust, isJust)
import qualified "containers" Data.Set as Set
import "base" Data.Function (fix)

import qualified "X11" Graphics.X11.Types      as XTypes
import qualified "X11" Graphics.X11.ExtraTypes as XTypes
import "X11" Graphics.X11.Xlib.Types (Display)
import "X11" Graphics.X11.Types (Window)

-- local imports

import Utils.StateMonad (EitherStateT, modifyState, modifyStateM)
import Utils.Sugar ((&), (.>), (|?|), (?))
import Utils.String (qm)
import qualified Options as O
import qualified Actions
import qualified State
import qualified Keys

import qualified Process.CrossThread as CrossThread
  ( handleCapsLockModeChange
  , handleAlternativeModeChange
  , handleResetKbdLayout

  , toggleCapsLock
  , toggleAlternative

  , resetAll
  )


type KeyCode         = XTypes.KeyCode
type Handle          = IOHandle.Handle
type Set             = Set.Set

type Options         = O.Options
type KeyMap          = Keys.KeyMap
type KeyName         = Keys.KeyName
type KeyAlias        = Keys.KeyAlias
type State           = State.State
type CrossThreadVars = State.CrossThreadVars


-- Wait for key events and simulate them in X server.
handleKeyboard :: CrossThreadVars -> Options -> KeyMap -> Display -> Handle
               -> IO ()
handleKeyboard ctVars opts keyMap _ fd =
  onEv $ fix $ \again keyName keyCode isPressed state ->

  let pressed, otherPressed :: Set KeyName
      -- All pressed keys at this time.
      -- Curretly pressed or released key (`keyName`) automatically
      -- added to (or removed from) this Set at the same time.
      pressed = State.pressedKeys state
      -- All pressed keys at this time excluding currently pressed key
      otherPressed = Set.delete keyName pressed

      -- Alternative version of currently pressed or released key
      alternative :: Maybe (KeyName, KeyCode)
      alternative = O.alternativeMode opts ? getAlternative keyName $ Nothing

      onOnlyBothAltsPressed :: Bool
      onOnlyBothAltsPressed =
        O.alternativeMode opts &&
        let set = Set.fromList [Keys.AltLeftKey, Keys.AltRightKey]
         in keyName `Set.member` set && pressed == set

      -- When Alternative mode is on and current key has alternative map
      onAlternativeKey :: Bool
      onAlternativeKey = State.alternative state && isJust alternative

      onAppleMediaPressed :: Bool
      onAppleMediaPressed = Keys.FNKey `Set.member` pressed && isMedia keyName

      onOnlyTwoControlsPressed :: Bool
      onOnlyTwoControlsPressed =
        let ctrls = Set.fromList [Keys.ControlLeftKey, Keys.ControlRightKey]
            additionalControls = Set.fromList [Keys.CapsLockKey, Keys.EnterKey]
         in pressed == ctrls
         || (O.additionalControls opts && pressed == additionalControls)

      -- Caps Lock or Enter pressed (current key)
      -- but not Enter with modifiers.
      onAdditionalControlKey :: Bool
      onAdditionalControlKey =
        O.additionalControls opts &&
        keyName `elem` [Keys.CapsLockKey, Keys.EnterKey] &&
        not (
          keyName == Keys.EnterKey &&
          isJust (state ^. State.comboState' . State.isEnterPressedWithMods')
        )

      -- Caps Lock or Enter pressed (previously pressed)
      -- but ignoring just Enter with modifiers.
      onWithAdditionalControlKey :: Bool
      onWithAdditionalControlKey =
        O.additionalControls opts &&
        any (`Set.member` pressed) [Keys.CapsLockKey, Keys.EnterKey] &&
        not (
          Keys.EnterKey `Set.member` pressed &&
          Keys.CapsLockKey `Set.notMember` pressed &&
          isJust (state ^. State.comboState' . State.isEnterPressedWithMods')
        )

      -- Only for additional controls.
      -- Enter key just pressed after some modifiers (only) was pressed before.
      -- Or Enter key just released after pressed with some modes keys.
      onEnterOnlyWithMods :: Bool
      onEnterOnlyWithMods =
        O.additionalControls opts &&
        keyName == Keys.EnterKey &&

        let -- When Enter key just pressed
            -- after some modifiers pressed before.
            pressedCase =
              isPressed &&
              not (Set.null otherPressed) && -- Have some keys pressed
                                             -- along with Enter key.
              -- Enter key was pressed with modifiers only,
              -- not any other key was pressed before.
              Set.null (Set.foldr Set.delete otherPressed allModifiersKeys)

            -- When Enter key is just released
            -- and before it was pressed only with modifiers.
            releasedCase =
              not isPressed &&
              isJust (state ^. State.comboState' . State.isEnterPressedWithMods')

         in pressedCase || releasedCase

      -- When Enter pressed with only modifiers before and not released yet
      onEnterWithModsOnlyInProgress :: Bool
      onEnterWithModsOnlyInProgress =

        let lens = State.comboState' . State.isEnterPressedWithMods'
            mods = state ^. lens

         in O.additionalControls opts &&
            isJust mods &&
            keyName /= Keys.EnterKey &&

            -- Preventing infinite loop, it's already stored in state,
            -- so we're just going to handle it recursively again.
            not (isPressed && keyName `Set.member` fromJust mods)

      justTrigger, justAsTrigger, smartTrigger, alternativeTrigger :: IO ()
      justTrigger        = trigger   keyName keyCode isPressed
      justAsTrigger      = asTrigger keyName keyCode isPressed
      smartTrigger       = onAlternativeKey ? alternativeTrigger $ justTrigger
      alternativeTrigger = do
        let Just (keyNameTo, keyCodeTo) = alternative
        noise [qm| Triggering {isPressed ? "pressing" $ "releasing"}
                 \ of alternative {keyNameTo}
                 \ (X key code: {keyCodeTo}) by {keyName}... |]
        (isPressed ? pressKey $ releaseKey) keyCodeTo

      off :: KeyName -> IO ()
      off keyName =
        when (keyName `Set.member` pressed) $
          trigger keyName (fromJust $ getKeyCodeByName keyName) False

  in
  if

  | onEnterWithModsOnlyInProgress ->

    let lens = State.comboState' . State.isEnterPressedWithMods'
        Just pressedModifiers = state ^. lens
        rehandle = again keyName keyCode isPressed

     in if -- When Enter had been pressed only with modifiers
           -- and one of the modifiers released erlier than Enter.
           | not isPressed && keyName `Set.member` pressedModifiers -> do

             noise' [ [qm| In sequence of 'modifier(s) + Enter' combo
                         \ modifier ({keyName}) was released before Enter,
                         \ we're about to take it as 'modifier(s) + Enter'
                         \ ({Set.toList pressedModifiers} + {Keys.EnterKey}) |]

                    , [qm| Triggering pressing and releasing {Keys.EnterKey}
                         \ right now and
                         \ recursively calling handler again to release
                         \ modifier ({keyName})... |]
                    ]

             -- Triggering Enter pressing and releasing first
             let enterKeyCode = fromJust $ getKeyCodeByName Keys.EnterKey

                 -- Handle it recursively again (without flag in state)
                 -- to press modifier befure triggering Enter.
              in pressRelease Keys.EnterKey enterKeyCode

             -- Triggering releasing of modifier
             -- and flush modifiers for enter list in state.
             state
               & lens .~ Nothing
               & State.pressedKeys' %~ (Set.delete Keys.EnterKey)
               & rehandle

           -- Another modifier pressed, adding it to stored list
           | isPressed && keyName `Set.member` allModifiersKeys -> do

             noise' [ [qm| In sequence of 'modifiers + Enter' combo
                         \ another modifier ({keyName}) was pressed,
                         \ adding this modifier to state... |]

                    , [qm| Calling handler recursively again
                         \ to trigger modifier ({keyName}) key... |]
                    ]

             -- Let's trigger this modifier key by recursively handle it again
             state & lens . mapped %~ Set.insert keyName & rehandle

           -- Another key event, it's not 'Enter with modifiers only' anymore,
           -- it should be handled as additional control in this case.
           | otherwise -> do

             noise' [ [qm| In sequence of 'modifier(s) + Enter' combo
                         \ ({Set.toList pressedModifiers} + {Keys.EnterKey})
                         \ some another key was detected
                         \ ({keyName} was {isPressed ? "pressed" $ "released"}),
                         \ so it means it's not that kind of combo anymore,
                         \ Enter key will be interpreted as additional control
                         \ (it could be Ctrl+Shift+C for example) |]

                    , "Removing 'modifier(s) + Enter' flag from state\
                      \ and calling handler recursively again\
                      \ to handle Enter as additional control..."
                    ]

             state & lens .~ Nothing & rehandle

  -- Alternative mode on/off by Alts handling
  | onOnlyBothAltsPressed -> do

    noise "Two alts pressed, it means Alternative mode toggling"
    let toDelete = [Keys.AltLeftKey, Keys.AltRightKey]
    forM_ toDelete off
    state
      & State.pressedKeys' .~ foldr Set.delete pressed toDelete
      & toggleAlternative

  -- Hadling `FNKey` pressing on apple keyboard
  | keyName == Keys.FNKey ->

    if

    -- Prevent triggering when just pressed
    | isPressed -> return state

    -- When releasing `FNKey` after some media keys pressed
    | state ^. State.comboState' . State.appleMediaPressed' -> do
      restPressed <- releaseAppleMedia $ State.pressedKeys state
      state
        & State.comboState' . State.appleMediaPressed' .~ False
        & State.pressedKeys' .~ restPressed
        & return

    -- As `InsertKey` (because no media pressed)
    | otherwise -> do
      asPressRelease keyName keyCode
      return state

  -- When held `FNKey` on apple keyboard and press some media key
  | onAppleMediaPressed -> do
    noise [qm| Apple media key pressed, preventing triggering
             \ {Keys.FNKey} as {Keys.InsertKey}... |]
    smartTrigger
    return (state & State.comboState' . State.appleMediaPressed' .~ True)

  | onOnlyTwoControlsPressed -> do

    noise "Two controls pressed, it means Caps Lock mode toggling"

    off Keys.ControlLeftKey
    off Keys.ControlRightKey

    let toDelete = [Keys.ControlLeftKey, Keys.ControlRightKey]
                     ++ if O.additionalControls opts
                           then [Keys.CapsLockKey, Keys.EnterKey]
                           else []
     in state
          & State.pressedKeys' .~ foldr Set.delete pressed toDelete
          & toggleCapsLock

  -- Ability to press combos like Shift+Enter, Alt+Enter, etc.
  | onEnterOnlyWithMods ->

    let lens      = State.comboState' . State.isEnterPressedWithMods'
        Just mods = state ^. lens

     in if isPressed

           -- On Enter key pressed.
           -- Storing pressed modifiers in state.
           then set lens (Just otherPressed) state
                <$ noise [qm| {keyName} pressed only with modifiers for now,
                            \ storing these modifiers list in state... |]

           -- On Enter key released.
           -- Triggering Enter key pressing+releasing
           -- (with triggered modifiers before),
           -- so it means we're triggering modifier + Enter combo
           -- (like Shift+Enter, Ctrl+Enter, etc.).
           else do noise [qm| {keyName} released and had pressed before
                            \ only with modifiers, triggering it as
                            \ {Set.toList mods} + {keyName}... |]
                   set lens Nothing state <$ pressRelease keyName keyCode

  -- Handling of additional controls by `CapsLockKey` and `EnterKey`.
  -- They can't be pressed both in the same time here, it handled above.
  | onAdditionalControlKey ->

    let (withCombosFlagLens, pressedBeforeLens, controlKeyName) =
          case keyName of
               Keys.CapsLockKey ->
                 ( State.comboState' . State.isCapsLockUsedWithCombos'
                 , State.comboState' . State.keysPressedBeforeCapsLock'
                 , Keys.ControlLeftKey
                 )
               Keys.EnterKey ->
                 ( State.comboState' . State.isEnterUsedWithCombos'
                 , State.comboState' . State.keysPressedBeforeEnter'
                 , Keys.ControlRightKey
                 )
          :: (Lens' State Bool, Lens' State (Set KeyName), KeyName)
     in if

        -- Prevent triggering when just pressed.
        -- But store keys that hadn't released in time.
        | isPressed -> do
          unless (Set.null otherPressed) $
            noise' [ [qm| {keyName} was pressed with some another keys
                        \ that hadn't be released in time, these another keys
                        \ WONT be taken as combo with additional control |]
                   , [qm| Storing keys was pressed before {keyName}:
                        \ {Set.toList otherPressed}... |]
                   ]
          return (state & pressedBeforeLens .~ otherPressed)

        -- Trigger Control releasing because when you press
        -- `CapsLockKey` or `EnterKey` with combo (see below)
        -- it triggers Control pressing.
        | state ^. withCombosFlagLens -> do
          let keyCode = fromJust $ getKeyCodeByName controlKeyName
          noise' [ [qm| {keyName} released after pressed with combos,
                      \ it means it was interpreted as {controlKeyName} |]
                 , [qm| Triggering releasing of {controlKeyName}
                      \ (X key code: {keyCode})... |]
                 ]
          releaseKey keyCode
          return (state & withCombosFlagLens .~ False)

        -- Just triggering default aliased key code
        -- to `CapsLockKey` or `EnterKey`.
        | otherwise ->
          case keyName of
               Keys.CapsLockKey -> do

                 ( if O.realCapsLock opts
                      then pressRelease
                      else asPressRelease ) keyName keyCode

                 if O.resetByEscapeOnCapsLock opts
                    then execStateT (runEitherT resetAll) state
                    else return state

               Keys.EnterKey -> state <$ pressRelease keyName keyCode
               _ -> return state

  -- When either `CapsLockKey` or `EnterKey` pressed with combo.
  -- They couldn't be pressed both, it handled above.
  | onWithAdditionalControlKey ->

    let _f :: (KeyName, Lens' State Bool, Lens' State (Set KeyName), KeyName)
        _f | Keys.CapsLockKey `Set.member` pressed =
             ( Keys.CapsLockKey
             , State.comboState' . State.isCapsLockUsedWithCombos'
             , State.comboState' . State.keysPressedBeforeCapsLock'
             , Keys.ControlLeftKey
             )
           | Keys.EnterKey `Set.member` pressed =
             ( Keys.EnterKey
             , State.comboState' . State.isEnterUsedWithCombos'
             , State.comboState' . State.keysPressedBeforeEnter'
             , Keys.ControlRightKey
             )
        ( mainKeyName,
          withCombosFlagLens,
          pressedBeforeLens,
          controlKeyName ) = _f
        pressedBeforeList = state ^. pressedBeforeLens
     in if

        -- Some key is released and this key was pressed before
        -- additional control, so we just remove this key from
        -- list of keys that pressed before additional control.
        | not isPressed && (keyName `Set.member` pressedBeforeList) ->
          (state & pressedBeforeLens %~ Set.delete keyName) <$ smartTrigger

        -- When pressing of Control already triggered
        | state ^. withCombosFlagLens -> state <$ smartTrigger

        -- `CapsLockKey` or `EnterKey` pressed with combo,
        -- it means it should be interpreted as Control key.
        | otherwise -> do
          let keyCode = fromJust $ getKeyCodeByName controlKeyName
          noise [qm| {mainKeyName} pressed with combo,
                   \ triggering {controlKeyName}
                   \ (X key code: {keyCode})... |]
          pressKey keyCode -- Press Control before current key
          smartTrigger
          return (state & withCombosFlagLens .~ True)

  -- When Caps Lock remapped as Escape key.
  -- Resetting stuff (if it's enabled)
  -- and specific logging (noticing about remapping).
  | keyName == Keys.CapsLockKey && not (O.realCapsLock opts) ->
    if O.resetByEscapeOnCapsLock opts && not isPressed
       then justAsTrigger >> execStateT (runEitherT resetAll) state
       else state <$ justAsTrigger

  -- Usual key handling
  | otherwise -> state <$ smartTrigger

  where

  noise   = Actions.noise         opts ctVars ::  String  -> IO ()
  noise'  = Actions.noise'        opts ctVars :: [String] -> IO ()
  notify' = Actions.notifyXmobar' opts ctVars :: [String] -> IO ()

  pressKey        = Actions.pressKey        ctVars :: KeyCode -> IO ()
  releaseKey      = Actions.releaseKey      ctVars :: KeyCode -> IO ()
  pressReleaseKey = Actions.pressReleaseKey ctVars :: KeyCode -> IO ()

  getAlias :: EvdevEvent.Key -> Maybe KeyAlias
  getAlias = Keys.getAliasByKey keyMap

  getKeyCodeByName :: KeyName -> Maybe KeyCode
  getKeyCodeByName = Keys.getKeyCodeByName keyMap

  getRealKeyCodeByName :: KeyName -> Maybe KeyCode
  getRealKeyCodeByName = Keys.getRealKeyCodeByName keyMap

  -- isAlternative = Keys.isAlternative keyMap :: KeyName -> Bool
  getAlternative :: KeyName -> Maybe (KeyName, KeyCode)
  getAlternative = Keys.getAlternative keyMap

  isMedia  = Keys.isMedia keyMap  :: KeyName -> Bool
  getMedia = Keys.getMedia keyMap :: KeyName -> Maybe KeyCode

  getAsName    = Keys.getAsName keyMap    :: KeyName -> KeyName
  getExtraKeys = Keys.getExtraKeys keyMap :: KeyName -> Set KeyName

  toggleCapsLock :: State -> IO State
  toggleCapsLock = CrossThread.toggleCapsLock ctVars noise' keyMap

  toggleAlternative :: State -> IO State
  toggleAlternative = CrossThread.toggleAlternative noise' notify'

  handleCapsLockModeChange :: State -> IO State
  handleCapsLockModeChange =
    CrossThread.handleCapsLockModeChange ctVars noise' keyMap

  handleAlternativeModeChange :: State -> IO State
  handleAlternativeModeChange =
    O.alternativeMode opts
      ? CrossThread.handleAlternativeModeChange noise' notify'
      $ return

  handleResetKbdLayout :: State -> IO State
  handleResetKbdLayout = CrossThread.handleResetKbdLayout ctVars noise'

  resetAll :: EitherStateT State () IO ()
  resetAll = CrossThread.resetAll opts ctVars noise' notify' keyMap

  -- Wait and extract event, make preparations and call handler
  onEv :: (KeyName -> KeyCode -> Bool -> State -> IO State) -> IO ()
  onEv m = forever $ EvdevEvent.hReadEvent fd >>= \case

    Just EvdevEvent.KeyEvent
           { EvdevEvent.evKeyCode      = (getAlias -> Just (name, _, code))
           , EvdevEvent.evKeyEventType = (checkPress -> Just isPressed)
           }
             -> chain (name, isPressed) $ m name code isPressed

    _ -> return ()

    where checkPress :: EvdevEvent.KeyEventType -> Maybe Bool
          checkPress = \case EvdevEvent.Depressed -> Just True
                             EvdevEvent.Released  -> Just False
                             _ -> Nothing

  -- Composed prepare actions
  chain :: (KeyName, Bool) -> (State -> IO State) -> IO ()
  chain (keyName, isPressed) handleM = do

    -- Log key user pressed (even if it's ignored or replaced)
    noise [qm| {keyName} is {isPressed ? "pressed" $ "released"} |]

    let f :: State -> IO State
        f = ignoreDuplicates
         .> (>>= storeKey)
         .> (>>= lift . handleM)
         .> (>>= lift . handleResetKbdLayout)
         .> (>>= lift . handleCapsLockModeChange)
         .> (>>= lift . handleAlternativeModeChange)
         .> runEitherT
         .> fmap (either id id)
     in modifyMVar_ (State.stateMVar ctVars) f

    where -- Prevent doing anything when key state is the same
          ignoreDuplicates :: State -> EitherT State IO State
          ignoreDuplicates state =
            let pressed     = State.pressedKeys state
                isMember    = keyName `Set.member` pressed
                isDuplicate = isPressed == isMember
             in (isDuplicate ? left $ right) state

          -- Store key user pressed in state
          storeKey :: State -> EitherT State IO State
          storeKey state =
            let action = isPressed ? Set.insert $ Set.delete
             in return (state & State.pressedKeys' %~ action keyName)

  abstractRelease :: String -- `releaseMsg`
                  -> (KeyName -> String) -- `releaseItemMsgMask`
                  -> (KeyName -> Bool) -- `splitter`
                  -> (KeyName -> Maybe KeyCode) -- `getter`
                  -> Set KeyName -- `pressed`
                  -> IO (Set KeyName) -- returns rest of `pressed`
  abstractRelease releaseMsg releaseItemMsgMask splitter getter pressed = do
    let (toRelease, rest) = Set.partition splitter pressed
    when (Set.size toRelease > 0) $ do
      noise releaseMsg
      forM_ (Set.toList toRelease) $ \keyName -> do
        noise $ releaseItemMsgMask keyName
        let Just keyCode = getter keyName
         in releaseKey keyCode
    return rest

  -- Release alternative keys.
  -- Useful when alternative mode turns off not by both alts
  -- and key could be still pressed.
  -- -- It's commented because it's never used anywhere
  -- releaseAlternative :: Set KeyName -> IO (Set KeyName)
  -- releaseAlternative = abstractRelease
  --   "Releasing alternative keys during turning alternative mode off..."
  --   (\keyName -> [qm| Releasing alternative {keyName}
  --                   \ during turning alternative mode off... |])
  --   isAlternative
  --   (getAlternative .> fmap snd)

  -- Release apple media keys.
  -- Useful when user released `FNKey` erlier than media key.
  releaseAppleMedia :: Set KeyName -> IO (Set KeyName)
  releaseAppleMedia = abstractRelease
    [qm| Releasing held media keys of apple keyboard
       \ after {Keys.FNKey} released... |]
    (\keyName -> [qm| Releasing held media {keyName} of apple keyboard
                    \ after {Keys.FNKey} released... |])
    isMedia
    getMedia

  -- Simple triggering key user pressed to X server
  trigger :: KeyName -> KeyCode -> Bool -> IO ()
  trigger keyName keyCode isPressed = do
    noise [qm| Triggering {isPressed ? "pressing" $ "releasing"}
             \ of {keyName} (X key code: {keyCode})... |]
    (isPressed ? pressKey $ releaseKey) keyCode

  -- Trigger remapped key.
  -- Difference between `trigger` is that this one
  -- shows in log which key this key remapped to.
  asTrigger :: KeyName -> KeyCode -> Bool -> IO ()
  asTrigger keyName keyCode isPressed = do
    noise [qm| Triggering {isPressed ? "pressing" $ "releasing"}
             \ of {keyName} as {getAsName keyName}
             \ (X key code: {keyCode})... |]
    (isPressed ? pressKey $ releaseKey) keyCode

  -- Triggering both press and release events to X server
  pressRelease :: KeyName -> KeyCode -> IO ()
  pressRelease keyName keyCode = do
    noise [qm| Triggering pressing and releasing of {keyName}
             \ (X key code: {keyCode})... |]
    pressReleaseKey keyCode

  -- Triggering both press and release events to X server.
  -- Also write to log about to which key this key remapped.
  asPressRelease :: KeyName -> KeyCode -> IO ()
  asPressRelease keyName keyCode = do
    noise [qm| Triggering pressing and releasing
             \ of {keyName} as {getAsName keyName}
             \ (X key code: {keyCode})... |]
    pressReleaseKey keyCode

  -- Union of all modifiers keys
  allModifiersKeys :: Set KeyName
  allModifiersKeys = mods `Set.union` remappedMods
    where -- Just Set of modifiers keys
          mods :: Set KeyName
          mods = Set.fromList
            [ Keys.ControlLeftKey, Keys.ControlRightKey
            , Keys.SuperLeftKey,   Keys.SuperRightKey
            , Keys.AltLeftKey,     Keys.AltRightKey
            , Keys.ShiftLeftKey,   Keys.ShiftRightKey
            ]
          -- Other keys that was remapped as modifiers keys,
          -- that means they're modifiers too.
          -- For example `LessKey` is remapped to `ShiftLeftKey`,
          -- so it means that this key is modifier too.
          remappedMods :: Set KeyName
          remappedMods = Set.foldr (Set.union . getExtraKeys) Set.empty mods

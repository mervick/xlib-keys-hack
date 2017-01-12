-- Author: Viacheslav Lotsmanov
-- License: GPLv3 https://raw.githubusercontent.com/unclechu/xlib-keys-hack/master/LICENSE

{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

module Process.CrossThread
  ( handleCapsLockModeChange
  , handleAlternativeModeChange

  , toggleCapsLock
  , toggleAlternative

  , turnCapsLockMode
  , turnAlternativeMode

  , justTurnCapsLockMode

  , notifyAboutAlternative
  ) where

import "X11" Graphics.X11.Xlib (Display, KeyCode)

import "transformers" Control.Monad.Trans.Class (lift)
import "lens" Control.Lens ((.~), (%~), (^.), set, over, view, Lens')
import "either" Control.Monad.Trans.Either (EitherT, runEitherT, left, right)
import "transformers" Control.Monad.Trans.State (StateT, evalStateT, execStateT)
import qualified "mtl" Control.Monad.State.Class as St (MonadState(get, put))
import "transformers" Control.Monad.IO.Class (liftIO)

import qualified "containers" Data.Set as Set (null)
import "base" Data.Maybe (fromJust, isJust)

-- local imports

import Utils ((?), (<||>), (&), (.>), modifyState, modifyStateM)
import Utils.String (qm)
import Bindings.XTest (fakeKeyCodeEvent)
import Bindings.MoreXlib (getLeds)
import qualified State
import qualified Keys


type State    = State.State
type Noiser   = [String] -> IO ()
type Notifier = [String] -> IO ()
type KeyMap   = Keys.KeyMap

type ModeChangeLens = Lens' State (Maybe Bool)



-- Abstraction for handling delayed actions connected to keys
-- (Caps Lock mode or Alternative mode).
handleModeChange :: ModeChangeLens -- Lens for delayed mode change
                                   -- state that we handle.
                 -> (String, String) -- Info messages to write it to log
                 -> (State -> IO State) -- Monad that do something to handle it.
                                        -- You can change the state here
                                        -- and it will be stored!
                                        -- It can reset mode by simulating
                                        -- some keys events for example.
                 -> Bool -- Flag that indicates current state of mode
                         -- that we handle.
                 -> Display -> Noiser -> KeyMap -> State -> IO State
handleModeChange mcLens (doneMsg, alreadyMsg) doHandle isNowOn
                 dpy noise' keyMap state =

  flip execStateT state . runEitherT $ do

  -- Remove delayed task if it's already done
  if hasDelayed && isAlreadyDone -- Nothing to do, already done
     then liftIO (noise' [alreadyMsg])
            >> modifyState (mcLens .~ Nothing)
            >> left ()
     else right () -- Go further

  -- Do nothing if Caps Lock mode changing is not requested
  -- or if all another keys isn't released yet.
  if hasDelayed && everyKeyIsReleased
     then right ()
     else left ()

  -- Handling it!
  modifyStateM $ liftIO . doHandle -- State can be modified there
  liftIO $ noise' [doneMsg]
  modifyState $ mcLens .~ Nothing -- Reset delayed mode change

  where hasDelayed         = (isJust   $ state ^. mcLens)         :: Bool
        toOn               = (fromJust $ state ^. mcLens)         :: Bool
        isAlreadyDone      = (toOn == isNowOn)                    :: Bool
        everyKeyIsReleased = (Set.null $ State.pressedKeys state) :: Bool


-- Handle delayed Caps Lock mode change
handleCapsLockModeChange :: Display -> Noiser -> KeyMap -> State -> IO State
handleCapsLockModeChange dpy noise' keyMap state =

  handleModeChange mcLens (doneMsg, alreadyMsg) handler isNowOn
                   dpy noise' keyMap state

  where doneMsg = [qm| Delayed Caps Lock mode turning
                     \ {toOn ? "on" $ "off"}
                     \ after all other keys release
                     \ (by pressing and releasing {keyName})... |]

        alreadyMsg = [qm| Delayed Caps Lock mode turning
                        \ {toOn ? "on" $ "off"}
                        \ after all other keys release is skipped
                        \ because it's already done now |]

        mcLens :: ModeChangeLens
        mcLens = State.comboState' . State.capsLockModeChange'

        toOn    = (fromJust $ state ^. mcLens)                :: Bool
        isNowOn = (state ^. State.leds' . State.capsLockLed') :: Bool

        handler :: State -> IO State
        handler s = const s <$> changeCapsLockMode dpy keyCode

        keyName = Keys.RealCapsLockKey
        keyCode = fromJust $ Keys.getRealKeyCodeByName keyMap keyName


-- Handle delayed Alternative mode change
handleAlternativeModeChange :: Display -> Noiser -> Notifier -> KeyMap -> State
                            -> IO State
handleAlternativeModeChange dpy noise' notify' keyMap state =

  handleModeChange mcLens (doneMsg, alreadyMsg) handler isNowOn
                   dpy noise' keyMap state

  where doneMsg = [qm| Delayed Alternative mode turning
                     \ {toOn ? "on" $ "off"}
                     \ after all other keys release... |]

        alreadyMsg = [qm| Delayed Alternative mode turning
                        \ {toOn ? "on" $ "off"}
                        \ after all other keys release is skipped
                        \ because it's already done now |]

        mcLens :: ModeChangeLens
        mcLens = State.comboState' . State.alternativeModeChange'

        toOn    = (fromJust $ state ^. mcLens)  :: Bool
        isNowOn = (state ^. State.alternative') :: Bool

        handler :: State -> IO State
        handler = changeAlternativeMode toOn
                   .> (\s -> const s <$> notifyAboutAlternative notify' s)



-- Abstraction for turning mode (caps lock/alternative) on/off
turnMode :: ModeChangeLens -- Lens for delayed mode change
                           -- to toggle it later if it's
                           -- bad time for that now.
         -> ([String], [String]) -- Info messages to log
         -> Maybe (Bool, [String]) -- Previous state and message
                                   -- if it's already done.
         -> (State -> IO State) -- Handler to call if it's possible right now.
                                -- It's possible to change state there
                                -- and it will be stored.
         -> Bool -- State to turn in ON or OFF
         -> Display -> Noiser -> KeyMap -> State -> IO State
turnMode mcLens (immediatelyMsgs, laterMsgs) already nowHandle toOn
         dpy noise' keyMap state =

  flip execStateT state . runEitherT $ do

  -- It's already done
  if isJust already && let Just (isNowOn, _) = already
                        in toOn == isNowOn
     then let (_, alreadyMsgs) = fromJust already
           in liftIO (noise' alreadyMsgs)
                >> modifyState (mcLens .~ Nothing) -- Clear possible previous
                                                   -- delayed action.
                >> left ()
     else right () -- Go further

  -- Doing it right now
  if Set.null (State.pressedKeys state)
     then liftIO (noise' immediatelyMsgs)
            >> modifyStateM (liftIO . nowHandle) -- State can be modified there
            >> modifyState  (mcLens .~ Nothing)  -- Clear possible previous
                                                 -- delayed action.
            >> left ()
     else right () -- Or not, go further

  -- Let's do it later
  liftIO $ noise' laterMsgs
  modifyState $ mcLens .~ Just toOn



toggleCapsLock :: Display -> Noiser -> KeyMap -> State -> IO State
toggleCapsLock dpy noise' keyMap state =

  turnMode mcLens ([immediatelyMsg], laterMsgs) Nothing handler toOn
           dpy noise' keyMap state

  where immediatelyMsg =
            [qm| Toggling Caps Lock mode (turning it {onOrOff toOn}
               \ by pressing and releasing {keyName})... |]

        laterMsgs = [ [qm| Attempt to toggle Caps Lock mode
                         \ (to turn it {onOrOff toOn}
                         \ by pressing and releasing {keyName})
                         \ while pressed some another keys |]

                    , [qm| Storing in state request to turn Caps Lock mode
                         \ {onOrOff toOn} after all another keys release... |]
                    ]

        mcLens :: ModeChangeLens
        mcLens  = State.comboState' . State.capsLockModeChange'

        toOn    = (not $ state ^. State.leds' . State.capsLockLed') :: Bool

        keyName = Keys.RealCapsLockKey
        keyCode = fromJust $ Keys.getRealKeyCodeByName keyMap keyName

        handler :: State -> IO State
        handler s = const s <$> changeCapsLockMode dpy keyCode


toggleAlternative :: Display -> Noiser -> Notifier -> KeyMap -> State
                  -> IO State
toggleAlternative dpy noise' notify' keyMap state =

  turnMode mcLens ([immediatelyMsg], laterMsgs) Nothing handler toOn
           dpy noise' keyMap state

  where immediatelyMsg = [qm| Toggling Alternative mode
                            \ (turning it {onOrOff toOn})... |]

        laterMsgs = [ [qm| Attempt to toggle Alternative mode
                         \ (to turn it {onOrOff toOn})
                         \ while pressed some another keys |]

                    , [qm| Storing in state request to turn Alternative mode
                         \ {onOrOff toOn} after all another keys release... |]
                    ]

        mcLens :: ModeChangeLens
        mcLens  = State.comboState' . State.alternativeModeChange'

        toOn    = (not $ state ^. State.alternative') :: Bool

        handler :: State -> IO State
        handler = changeAlternativeMode toOn
                   .> (\s -> const s <$> notifyAboutAlternative notify' s)



turnCapsLockMode :: Display -> Noiser -> KeyMap -> State -> Bool -> IO State
turnCapsLockMode dpy noise' keyMap state toOn =

  turnMode mcLens ([immediatelyMsg], laterMsgs) already handler toOn
           dpy noise' keyMap state

  where immediatelyMsg = [qm| Turning Caps Lock mode {onOrOff toOn}
                            \ (by pressing and releasing {keyName})... |]

        laterMsgs = [ [qm| Attempt to turn Caps Lock mode {onOrOff toOn}
                         \ (by pressing and releasing {keyName})
                         \ while pressed some another keys |]

                    , [qm| Storing in state request to turn Caps Lock mode
                         \ {onOrOff toOn} after all another keys release... |]
                    ]

        alreadyMsg = [qm| Attempt to turn Caps Lock mode {onOrOff toOn},
                        \ it's already done, skipping... |]

        mcLens :: ModeChangeLens
        mcLens  = State.comboState' . State.capsLockModeChange'

        isNowOn = (state ^. State.leds' . State.capsLockLed') :: Bool
        already = Just (isNowOn, [alreadyMsg]) :: Maybe (Bool, [String])

        keyName = Keys.RealCapsLockKey
        keyCode = fromJust $ Keys.getRealKeyCodeByName keyMap keyName

        handler :: State -> IO State
        handler s = const s <$> changeCapsLockMode dpy keyCode


turnAlternativeMode :: Display -> Noiser -> Notifier -> KeyMap -> State -> Bool
                    -> IO State
turnAlternativeMode dpy noise' notify' keyMap state toOn =

  turnMode mcLens ([immediatelyMsg], laterMsgs) already handler toOn
           dpy noise' keyMap state

  where immediatelyMsg = [qm| Turning Alternative mode {onOrOff toOn}... |]

        laterMsgs = [ [qm| Attempt to turn Alternative mode {onOrOff toOn}
                         \ while pressed some another keys |]

                    , [qm| Storing in state request to turn Alternative mode
                         \ {onOrOff toOn} after all another keys release... |]
                    ]

        alreadyMsg = [qm| Attempt to turn Alternative mode {onOrOff toOn},
                        \ it's already done, skipping... |]

        mcLens :: ModeChangeLens
        mcLens  = State.comboState' . State.alternativeModeChange'

        isNowOn = (state ^. State.alternative') :: Bool
        already = Just (isNowOn, [alreadyMsg])  :: Maybe (Bool, [String])

        handler :: State -> IO State
        handler = changeAlternativeMode toOn
                   .> (\s -> const s <$> notifyAboutAlternative notify' s)



-- Turns Caps Lock mode on/off without checking pressed keys
-- but checks for led state.
justTurnCapsLockMode :: Display -> (String -> IO ()) -> KeyMap -> Bool -> IO ()
justTurnCapsLockMode dpy noise keyMap isOn =

  let log = noise [qm| Turning Caps Lock mode {onOrOff isOn}
                     \ (by pressing and releasing {keyName})... |]
      f = fakeKeyCodeEvent dpy keyCode
      toggle = f True >> f False
      -- Sometimes for some reason Caps Lock mode led returns True
      -- at initialization step even if Caps Lock mode is disabled,
      -- let's bang Caps Lock key until it is really disabled.
      recur = do
        toggle
        (view State.capsLockLed' -> isReallyOn) <- getLeds dpy
        isReallyOn /= isOn ? recur $ return ()
   in log >> recur

  `or`

  noise [qm| Attempt to turn Caps Lock mode {onOrOff isOn},
           \ it's already done, skipping... |]

  where keyName = Keys.RealCapsLockKey
        keyCode = fromJust $ Keys.getRealKeyCodeByName keyMap keyName

        or :: IO () -> IO () -> IO ()
        a `or` b = do
          (view State.capsLockLed' -> isOnAlready) <- getLeds dpy
          isOn /= isOnAlready ? a $ b



-- Caps Lock mode change bare handler
changeCapsLockMode :: Display -> KeyCode -> IO ()
changeCapsLockMode dpy keyCode = f True >> f False
  where f = fakeKeyCodeEvent dpy keyCode

-- Alternative mode change bare handler
changeAlternativeMode :: Bool -> State -> State
changeAlternativeMode toOn = State.alternative' .~ toOn


-- Notify xmobar about Alternative mode state
notifyAboutAlternative :: Notifier -> State -> IO ()
notifyAboutAlternative notify' state =
  notify' [msg $ state ^. State.alternative']
  where msg = "alternative:on\n" <||> "alternative:off\n"


onOrOff :: Bool -> String
onOrOff = "on" <||> "off"
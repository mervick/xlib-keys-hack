-- Author: Viacheslav Lotsmanov
-- License: GPLv3 https://raw.githubusercontent.com/unclechu/xlib-keys-hack/master/LICENSE

{-# LANGUAGE OverloadedStrings #-}

module IPC
  ( IPCHandle
  , openIPC
  , closeIPC
  , setIndicatorState
  , logView
  ) where

import "base" Data.Maybe (fromMaybe)
import "qm-interpolated-string" Text.InterpolatedString.QM (qm)

import "dbus" DBus ( ObjectPath
                   , objectPath_
                   , BusName
                   , busName_
                   , InterfaceName
                   , interfaceName_
                   , signal
                   , signalDestination
                   , IsVariant(toVariant)
                   , Signal(signalBody)
                   )

import "dbus" DBus.Client ( Client
                          , disconnect
                          , connectSession
                          , emit
                          , matchAny
                          , addMatch
                          , removeMatch
                          , SignalHandler

                          , MatchRule ( matchPath
                                      , matchInterface
                                      , matchSender
                                      , matchDestination
                                      , matchMember
                                      )
                          )

-- local imports

import Utils.Sugar ((<&>))
import qualified Options as O
import Actions ( XmobarFlag ( XmobarNumLockFlag
                            , XmobarCapsLockFlag
                            , XmobarAlternativeFlag
                            , XmobarFlushAll
                            )
               )

type Options = O.Options


data IPCHandle = IPCHandle { dbusClient            :: Client
                           , xmobarObjectPath      :: ObjectPath
                           , xmobarBus             :: Maybe BusName
                           , xmobarInterface       :: InterfaceName
                           , xmobarFlushObjectPath :: ObjectPath
                           , xmobarFlushInterface  :: InterfaceName
                           , xmobarFlushSigHandler :: SignalHandler
                           }


openIPC :: String -> Options -> IO () -> IO IPCHandle
openIPC dpyName opts flushAllCallback = do

  dbusSession <- connectSession

  let path  = fromMaybe "/"
            $ O.xmobarIndicatorsObjPath opts <&> objectPath_

      bus   = let opt = O.xmobarIndicatorsBusName opts
               in if opt == Just "any"
                     then Nothing
                     else Just $ busName_ $ fromMaybe xmobarBusNameDef opt

      iface = defIface $ O.xmobarIndicatorsIface opts <&> interfaceName_

      flushObjPath = objectPath_
                   $ fromMaybe flushObjPathDef
                   $ O.xmobarIndicatorsFlushObjPath opts

      flushIface = defIface
                 $ O.xmobarIndicatorsFlushIface opts <&> interfaceName_

      flushMatchRule = matchAny { matchPath        = Just flushObjPath
                                , matchSender      = Nothing
                                , matchDestination = Nothing
                                , matchInterface   = Just flushIface
                                , matchMember      = Just "request_flush_all"
                                }

  sigHandler <- addMatch dbusSession flushMatchRule flushHandle

  return IPCHandle { dbusClient            = dbusSession
                   , xmobarObjectPath      = path
                   , xmobarBus             = bus
                   , xmobarInterface       = iface
                   , xmobarFlushObjectPath = flushObjPath
                   , xmobarFlushInterface  = flushIface
                   , xmobarFlushSigHandler = sigHandler
                   }

  where xmobarBusNameDef = "com.github.unclechu.xmonadrc." ++ dpyView
        flushObjPathDef = "/com/github/unclechu/xmonadrc/" ++ dpyView
        defIface = fromMaybe "com.github.unclechu.xmonadrc"

        dpyView = let f ':' = '_'; f '.' = '_'; f x = x
                   in map f dpyName

        flushHandle (signalBody -> []) = flushAllCallback
        flushHandle _ = return () -- Incorrect arguments, just ignoring it


closeIPC :: IPCHandle -> IO ()
closeIPC IPCHandle { dbusClient = c
                   , xmobarFlushSigHandler = sigH
                   } = removeMatch c sigH >> disconnect c


setIndicatorState :: IPCHandle -> XmobarFlag -> IO ()
setIndicatorState IPCHandle { dbusClient = c
                            , xmobarObjectPath = path
                            , xmobarBus = bus
                            , xmobarInterface = iface
                            }
                  flag =

  emit c (signal path iface member)
           { signalDestination = bus
           , signalBody        = [toVariant isOn]
           }

  where (member, isOn) = case flag of

                              XmobarNumLockFlag     x -> ("numlock",     x)
                              XmobarCapsLockFlag    x -> ("capslock",    x)
                              XmobarAlternativeFlag x -> ("alternative", x)

                              XmobarFlushAll -> error "unexpected value"


logView :: IPCHandle -> String
logView IPCHandle { xmobarObjectPath      = objPath
                  , xmobarBus             = bus
                  , xmobarInterface       = iface
                  , xmobarFlushObjectPath = flushObjPath
                  , xmobarFlushInterface  = flushIface
                  } =

  [qm| IPC data (DBus):\n
      \  xmobar bus name: {busView}\n
      \  xmobar object path: {objPath}\n
      \  xmobar interface name: {iface}\n
      \  xmobar object path for listening for flush requests: {flushObjPath}\n
      \  xmobar interface name for listening for flush requests: {flushIface}
     |]

  where busView = fromMaybe "any (broadcasting to everyone)" $ fmap show bus
{-# LANGUAGE QuasiQuotes, TemplateHaskell #-}
module Handler.User
    ( getUserR
    , getByIdentR
    , postFlagR
    , adminControls
    ) where

import Haskellers
import Handler.Root (gravatar)
import Data.List (sort)
import Data.Maybe (fromMaybe)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.UTF8 as SU
import OpenSSL.Cipher
import OpenSSL.EVP.Base64
import System.IO.Unsafe (unsafePerformIO)
import Yesod.Form.Jquery (urlJqueryJs)
import Data.Time (getCurrentTime)

getByIdentR :: Handler RepJson
getByIdentR = do
    identS <- runFormGet' $ stringInput "ident"
    x <- runDB $ getBy $ UniqueIdent identS
    render <- getUrlRender
    case x of
        Nothing -> notFound
        Just (_, Ident { identUser = uid }) -> jsonToRepJson $ jsonMap
            [ ("id", jsonScalar $ showIntegral uid)
            , ("url", jsonScalar $ render $ UserR $ showIntegral uid)
            ]

getUserR :: String -> Handler RepHtmlJson
getUserR input = do
    (uid, u) <-
        case readIntegral input of
            Just uid -> do
                u <- runDB $ get404 uid -- FIXME add an automatic 301 if there is a username
                return (uid, u)
            _ -> notFound
    mv <- maybeAuth
    let viewerIsAdmin = maybe False (userAdmin . snd) mv
    skills <- runDB $ do
        x <- selectList [UserSkillUserEq uid] [] 0 0
        y <- mapM (get404 . userSkillSkill . snd) x
        return $ sort $ map skillName y
    packages <- runDB
              $ fmap (map $ packageName . snd)
              $ selectList [PackageUserEq uid] [PackageNameAsc] 0 0
    let email = fromMaybe "fake@email.com" $ userEmail u
    y <- getYesod
    let json = jsonMap
            $ ((:) ("id", jsonScalar $ showIntegral uid))
            . ((:) ("name", jsonScalar $ userFullName u))
            . (case userWebsite u of
                Nothing -> id
                Just w -> (:) ("website", jsonScalar w))
            . (case userHaskellSince u of
                Nothing -> id
                Just e -> (:) ("haskell-since", jsonScalar $ show e))
            . (case userDesc u of
                Nothing -> id
                Just d -> (:) ("description", jsonScalar $ unTextarea d))
            . ((:) ("skills", jsonList $ map jsonScalar skills))
            $ []
    flip defaultLayoutJson json $ do
        setTitle $ string $ "Haskellers profile for " ++ userFullName u
        addStyle $(cassiusFile "user")
        addScriptEither $ urlJqueryJs y
        addJavascript $(juliusFile "user")
        $(hamletFile "user")
  where
    notOne 1 = False
    notOne _ = True

mailhidePublic :: String
mailhidePublic = "01_o4fjI3uXdNz6rLrIquvlw=="

mailhidePrivate :: S.ByteString
mailhidePrivate = S8.pack "\x42\x40\x54\x79\x07\x8c\x47\xb0\x50\xd7\x9a\x33\xc6\x09\x69\x1c"

emailLink :: String -> String
emailLink email = unsafePerformIO $ do
    enc <- encryptAddress email
    return $ concat
        [ "http://www.google.com/recaptcha/mailhide/d?k="
        , mailhidePublic
        , "&c="
        , enc
        ]

encryptAddress :: String -> IO String
encryptAddress =
    fmap (map b64Url . S8.unpack . encodeBase64BS) . encrypt . pad
  where
    b64Url '+' = '-'
    b64Url '/' = '_'
    b64Url c   = c

pad :: String -> S.ByteString
pad s =
    let bs' = SU.fromString s
        blockSize = 16
        numpad = blockSize - (S.length bs' `mod` blockSize)
        padding = S.replicate numpad $ fromIntegral numpad
     in bs' `S.append` padding

encrypt :: S.ByteString -> IO S.ByteString
encrypt bs = do
    ctx <- newAESCtx Encrypt mailhidePrivate $ S.replicate 16 0
    aesCBC ctx bs

postFlagR :: UserId -> Handler ()
postFlagR uid = do
    mvid <- fmap (fmap fst) maybeAuth

    u <- runDB $ do
        u <- get404 uid
        now <- liftIO getCurrentTime
        _ <- insert Message
            { messageClosed = False
            , messageWhen = now
            , messageFrom = mvid
            , messageRegarding = Just uid
            , messageText = Textarea "User has been reported"
            }
        return u
    setMessage $ string "The user has been reported to the admins. Thanks!"
    redirect RedirectTemporary $ userR (uid, u)

adminControls :: UserId -> User -> Widget Haskellers ()
adminControls uid u = do
    addStyle $(cassiusFile "admin-controls")
    $(hamletFile "admin-controls")

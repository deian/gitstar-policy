{-# LANGUAGE CPP #-}
#if PRODUCTION
{-# LANGUAGE Safe #-}
#endif
{-# LANGUAGE OverloadedStrings, DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses, IncoherentInstances #-}
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
-- | This module export the core gitstar model and types.
module Gitstar.Policy ( gitstar
                      , GitstarPolicy
                      -- * Privileged insert/delete
                      , gitstarInsertRecord
                      , gitstarInsertLabeledRecord
                      , gitstarSaveRecord
                      , gitstarSaveLabeledRecord
                      -- * Projects
                      , ProjectName, ProjectId, Project(..), Public(..)
                      , GitstarApp(..)
                      , mkProject, createProject
                      , updateUserWithProjId
                      , partialProjectUpdate
                      -- * Users
                      , UserName, Url, User(..), SSHKey(..)
                      , getOrCreateUser
                      , partialUserUpdate 
                      , addUserKey 
                      , delUserKey 
                      -- * HTTP access to git API
                      , gitstarRepoHttp
                      ) where

import Prelude hiding (lookup)
import Config

import Control.Monad

import Data.Maybe
import Data.List (isInfixOf, stripPrefix)
import qualified Data.List as List
import Data.Typeable
import Hails.Data.LBson hiding ( map, head, break
                               , tail, words, key, filter
                               , dropWhile, drop, split, foldl
                               , notElem, isInfixOf)

import Hails.App
import Hails.Database
import Hails.Database.MongoDB hiding ( Action, map, head, break
                                     , tail, words, key, filter
                                     , dropWhile, drop, split, foldl
                                     , notElem, isInfixOf)
import Hails.Database.MongoDB.Structured
import Data.IterIO.Http
import Hails.IterIO.HttpClient

import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.Lazy.Char8 as L8

import LIO.MonadCatch
import Gitstar.Models

-- | Policy handler
gitstar :: DC GitstarPolicy
gitstar = mkPolicy

-- | Internal gitstar policy. The type constructor should not be
-- exported as to avoid leaking the privilege.
data GitstarPolicy = GitstarPolicy TCBPriv (Database DCLabel)
  deriving (Typeable)

instance DatabasePolicy GitstarPolicy where
  createDatabasePolicy conf p = do
    db <- labelDatabase conf lcollections lpub
    db' <- foldM (\d col -> do
              c <- col p
              assocCollectionP p c d) db [ projectsCollection
                                         , usersCollection
                                         , appsCollection
                                         ]
    return $ GitstarPolicy p db'
      where lcollections = newDC (<>) (owner p)

  policyDB (GitstarPolicy _ db) = db

instance MkToLabeledDocument GitstarPolicy where
  mkToLabeledDocument (GitstarPolicy privs _) = toDocumentP privs
    

instance PolicyGroup GitstarPolicy where
  expandGroup self princ = 
    let princName = S8.unpack $ name princ
        groupPrefixi = [("#canread_",readers), ("#canwrite_",writers)]
        mpref = List.find (\x -> fst x `List.isPrefixOf` princName) groupPrefixi
    in case mpref of
         Nothing -> return [princ]
         Just (prefix, func) ->  do
           let projId = read . doStripPrefix prefix $ princName :: ObjectId
           mproj <- liftLIO $ findBy self "projects" "_id" projId
           return $ maybe [princ] (map principal . func) mproj
    where readers proj = case projectReaders proj of
                           Right rdrs -> writers proj ++ rdrs
                           Left _ -> []
          writers proj = (projectOwner proj):(projectCollaborators proj)
          doStripPrefix p = fromJust . stripPrefix p
  
  relabelGroups self@(GitstarPolicy p _) = relabelGroupsP self p

-- | Extract the principal of a DCLabel singleton component.
extractPrincipal :: Component -> Maybe Principal
extractPrincipal c | c == (><) = Nothing
                   | otherwise =  case componentToList c of
                                    [MkDisj [p]] -> Just p
                                    _ -> Nothing

-- | Get the only principal that owns the privileges.
-- Note that this will result in an error if the privilege is 
-- not a list of one principal
owner :: DCPrivTCB -> String
owner = S8.unpack . name . fromJust . extractPrincipal . priv

--
-- Insert and save recors with gitstar privileges
--

-- | Insert a record into the gitstar database, using privileges to
-- downgrade the current label for the insert.
gitstarInsertRecord :: DCRecord a => a -> DC (Either Failure (Value DCLabel))
gitstarInsertRecord = gitstarInsertOrSaveRecord insertRecord

-- | Insert a labeled record into the gitstar database, using privileges to
-- downgrade the current label for the insert.
gitstarInsertLabeledRecord :: DCLabeledRecord a
                           => DCLabeled a -> DC (Either Failure (Value DCLabel))
gitstarInsertLabeledRecord =
  gitstarInsertOrSaveLabeledRecord insertLabeledRecord

-- | Save a record into the gitstar database, using privileges to
-- downgrade the current label for the save.
gitstarSaveRecord :: DCRecord a => a -> DC (Either Failure ())
gitstarSaveRecord = gitstarInsertOrSaveRecord saveRecord

-- | Save a labeled record into the gitstar database, using privileges to
-- downgrade the current label for the save.
gitstarSaveLabeledRecord :: DCLabeledRecord a
                           => DCLabeled a -> DC (Either Failure ())
gitstarSaveLabeledRecord = gitstarInsertOrSaveLabeledRecord saveLabeledRecord

--
-- Users
--

-- | Collection keeping track of users
-- /Security properties:/
--
--   * User name and ssh-key are searchable
--
--   * Only gitstar or user may modify the ssh key and project list
--
usersCollection :: TCBPriv -> DC (Collection DCLabel)
usersCollection p = collectionP p "users" lpub colClearance $
  RawPolicy (userLabel . fromJust . fromDocument)
            [ ("_id", SearchableField)
            , ("key", SearchableField)
            ]
   where userLabel usr = newDC (<>) ((userName usr) .\/. (owner p))
         colClearance = newDC (owner p) (<>)


-- | Get the user and if it's not already in the DB, insert it.
getOrCreateUser :: UserName -> DC User
getOrCreateUser uName = do
  policy@(GitstarPolicy privs _) <- gitstar
  mres   <- findBy policy  "users" "_id" uName
  case mres of
    Just usr -> return usr
    _ -> do res <- insertRecordP privs policy newUser
            either (err "Failed to create user") (const $ return newUser) res
    where newUser = User { userName = uName
                         , userKeys = []
                         , userProjects = []
                         , userFullName = Nothing
                         , userCity = Nothing
                         , userWebsite = Nothing
                         , userGravatar = Nothing }
          err m _ = throwIO . userError $ m

-- | Execute a \"toLabeled\" gate with gitstar prvileges
-- Note this downgrades the current label of the inner computation and
-- so privileges and so should not be exported.
gitstarToLabeled :: DCLabeled (Document DCLabel)
                 -> (Document DCLabel -> DC a) -> DC (DCLabeled a)
gitstarToLabeled ldoc act = do
  (GitstarPolicy privs _) <- gitstar
  gateToLabeled privs ldoc act

-- | Given a user name and partial document for a 'User', return a
-- labeld user (endorsed by the policy). The projects, user
-- id, and keys are not modified if present in the document.
-- To modify the keys use 'addUserKey' and 'delUserKey'.
-- To modify the projects field use 'updateUserWithProjId'.
partialUserUpdate :: UserName
                  -> DCLabeled (Document DCLabel)
                  -> DC (DCLabeled User)
partialUserUpdate username ldoc = do
  user <- getOrCreateUser username
  gitstarToLabeled ldoc $ \partialDoc ->
        -- Do not touch the user name and projects:
    let protected_fields = ["projects", "_id", "keys"]
        doc0 = exclude protected_fields partialDoc
        doc1 = toDocument user
    in fromDocument $ merge doc0 doc1 -- create new user


-- | Given a username and a labeled document corresponding to a key,
-- find the user in the DB and return a 'User' value with the key
-- added. The resultant value is endorsed by the policy/service.
addUserKey :: UserName -> DCLabeled (Document DCLabel) -> DC (DCLabeled User)
addUserKey username ldoc = do
  user <- getOrCreateUser username
  gitstarToLabeled ldoc $ \doc -> do
    -- generate a new key id:
    newId <- genObjectId
    -- The key value is expected to be a string, which we convert to
    -- 'Binary' to match types
    v <- mkKeyValueBinary doc 
    -- create key object:
    key <- fromDocument $ merge ["_id" =: newId, "value" =: v] doc
    -- Return the new user:
    return $ user { userKeys = key : userKeys user }
      where mkKeyValueBinary doc = 
              (Binary . S8.pack) `liftM` lookup (u "value")  doc

-- | Given a username and a labeled document containing the key id,
-- find the user in the DB and return a 'User' value with the key
-- delete. The resultant value is endorsed by the policy/service.
delUserKey :: UserName -> DCLabeled (Document DCLabel) -> DC (DCLabeled User)
delUserKey username ldoc = do
  user <- getOrCreateUser username
  gitstarToLabeled ldoc $ \doc -> do
    let mkId = lookup "_delete" doc >>= maybeRead
        keys = case mkId of
                 Just kId -> filter ((/=kId) . sshKeyId) $ userKeys user
                 _ -> userKeys user
    return $ user { userKeys = keys }

--
-- Apps
--

-- | Collection keeping track of registered Gitstar Apps
-- /Security properties:/
--
--   * All fields are searchable and everything is publicly readable
--
--   * Only gitstar and owner may modify document
--
appsCollection :: TCBPriv -> DC (Collection DCLabel)
appsCollection p = collectionP p "apps" lpub colClearance $
  RawPolicy (labelForApp . fromJust . fromDocument)
            [ ("_id",   SearchableField)
            , ("name",  SearchableField)
            , ("title", SearchableField)
            , ("description", SearchableField)
            , ("owner", SearchableField)
            ]
    where colClearance = newDC (<>) (owner p)
          labelForApp proj = newDC (<>) (owner p .\/. appOwner proj)


--
-- Projects
--


-- | Collection keeping track of projects
-- /Security properties:/
--
--   * Project id, name and owner are searchable
--
--   * If the project is not public, only collaborators and readers
--     (and gitstar) may read the description and repository data
--
--   * Only gitstar and collaborators may write to the repository
--
--   * Only gitstar and owner may modify document
--
projectsCollection :: TCBPriv -> DC (Collection DCLabel)
projectsCollection p = collectionP p "projects" lpub colClearance $
  RawPolicy (labelForProject . fromJust . fromDocument)
            [ ("_id",   SearchableField)
            , ("name",  SearchableField)
            , ("owner", SearchableField)
            ]
    where colClearance = newDC (owner p) (<>)
          labelForProject proj = 
            let collabs = projectCollaborators proj
                r = case projectReaders proj of
                      Left Public -> (<>)
                      Right rs -> listToComponent [listToDisj $
                                    projectOwner proj:"gitstar":(rs ++ collabs)]
            in newDC (owner p .\/. r)
                     (projectOwner proj .\/.  owner p)



-- | Given a username and a labeled document containing
-- either:
--
-- * the project fields, create a labeled 'Project' from the
--   corresponding document.
--
-- * or @_fork@ field (containing the object id of an existing
--   project), create a labeled 'Project' by copying all but the
--   access-control fields of the project.
mkProject :: UserName -> DCLabeled (Document DCLabel)
                      -> DC (DCLabeled Project)
mkProject username ldoc = do
  void $ getOrCreateUser username
  taintForkedProj $ gitstarToLabeled ldoc $ \doc ->
    case lookup "_fork" doc of
      Nothing -> do
        fromDocument $ merge [ "owner"  =: username ] doc -- new proj
      Just pidS -> do
        policy@(GitstarPolicy privs _) <- gitstar
        let pid = Just $ read pidS
        proj <- findByP privs policy "projects" "_id" pid >>= maybe err return
        return $ proj { projectId            = Nothing
                      , projectOwner         = username
                      , projectCollaborators = []
                      , projectReaders       = Right []
                      , projectForkedFrom    = pid }
  where err = throwIO $ userError "mkProject failed to fork project"
        -- taint app to relfect reading of forked project:
        taintForkedProj io = do
          lproj <- io
          proj <- unlabel lproj
          policy <- gitstar
          let pid = projectForkedFrom proj
          void $ (findBy policy "projects" "_id" $ pid :: DC (Maybe Project))
          return lproj


-- | Given a user name and project ID, associate the project with the
-- user, if it's not already.
updateUserWithProjId :: UserName -> ProjectId -> DC ()
updateUserWithProjId username oid = do
  policy@(GitstarPolicy privs _) <- gitstar
  muser <- findBy policy  "users"    "_id" username
  mproj <- findBy policy  "projects" "_id" oid
  case (muser, mproj) of
    (Just usr, Just proj) -> do
      unless (username == projectOwner proj) $ err "User is not project owner"
      let projIds = userProjects usr
          newUser = usr { userProjects = oid : projIds }
      when (oid `notElem` projIds) $ void $ saveRecordP privs policy newUser
    _ -> err  "Expected valid user and project"
  where err = throwIO . userError

-- | Given a user name, project name, and partial project document,
-- retrive the project and merge the provided fields.
-- Note that the project id, name, owner and apps fields are kept
-- constant. To modify the apps, use 'addProjectApp'.
partialProjectUpdate :: UserName
                     -> ProjectName
                     -> DCLabeled (Document DCLabel)
                     -> DC (DCLabeled Project)
partialProjectUpdate username projname ldoc = do
  policy <- gitstar
  mproj <- findWhere policy $ select [ "name" =: projname
                                     , "owner" =: username ]
                                     "projects"
  case mproj of
    Just (proj@Project{}) -> gitstarToLabeled ldoc $ \doc ->
             -- Do not touch the project id, name and owner:
         let protected_fields = ["_id", "name", "owner"]
             doc0 = exclude protected_fields doc
             doc1 = case look (u "public") doc0 of
                      Just v | (v == (val True)) ||
                               (v == (val ("1" :: String))) ||
                               (v == (val ("on" :: String))) -> doc0
                             | (v == (val False)) ||
                               (v == (val ("0" :: String))) ||
                               (v == (val ("off" :: String))) -> doc0
                      _       -> ("public" =: (isPublic proj)):doc0
             -- readers/collaborators might correspond to empty list
             -- which is an input field of form: readers[]=""
             doc2 = filterEmptyList "readers" $
                    filterEmptyList "collaborators" doc1
         in fromDocument $ merge doc2 $ toDocument proj
    _ -> err  "Expected valid user and project"
  where err = throwIO . userError
        noName :: UserName
        noName = ""
        filterEmptyList fld d = 
          let mv = case lookup fld d of
                Just [x] | x == noName -> Just []
                Just xs                -> Just $ filter (/=noName) xs
                Nothing                -> Nothing
          in (maybe [] (\v -> [fld =: v]) mv) ++ exclude [fld] d

-- | Class used to crete gitstar projects
class CreteProject a where
  -- | Given a project, or labeled project insert it into the database
  -- and make a request to gitstar service to actually initialize the
  -- bare repository
  createProject :: a -> DC (Either Failure (Value DCLabel))

instance CreteProject Project where
  createProject proj = do
    res <- gitstarInsertRecord proj
    when (isRight res) $
      maybe gitstarCreateRepo gitstarForkRepo (projectForkedFrom proj)
                                              (projectOwner proj)
                                              (projectName proj)
    return res

instance CreteProject (DCLabeled Project) where
  createProject lproj = do
    res <- gitstarInsertLabeledRecord lproj
    when (isRight res) $ do
      proj <- unlabel lproj
      maybe gitstarCreateRepo gitstarForkRepo (projectForkedFrom proj)
                                              (projectOwner proj)
                                              (projectName proj)
    return res


--
-- Misc
--

-- | True if value is a 'Right'
isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _         = False

-- | Insert or save a labeled record using gitstar privileges to
-- untaint the current label (for the duration of the insert or save).
gitstarInsertOrSaveRecord :: DCRecord a
  => (GitstarPolicy -> a -> DC (Either Failure b))
  -> a
  -> DC (Either Failure b)
gitstarInsertOrSaveRecord f rec = do
  policy@(GitstarPolicy privs _) <- gitstar
  l <- getLabel
  withLabel privs (newDC (<>) (integrity l)) $ f policy rec

-- | Insert or save a labeled record using gitstar privileges to
-- untaint the current label (for the duration of the insert or save)
-- and record.
gitstarInsertOrSaveLabeledRecord :: DCLabeledRecord a
  => (GitstarPolicy -> DCLabeled a -> DC (Either Failure b))
  -> DCLabeled a
  ->  DC (Either Failure b)
gitstarInsertOrSaveLabeledRecord f lrec = do
  policy@(GitstarPolicy privs _) <- gitstar
  lcur <- getLabel
  lrec' <- untaintLabeledP privs (newDC (<>) (integrity . labelOf $ lrec)) lrec
  withLabel privs (newDC (<>) (integrity lcur)) $ f policy lrec'

--
-- Repo related
--

-- | Given user name, project name and URL suffix make GET request 
-- to gitstar-ssh-web server. This is the low-lever interface to
-- accessing git objects.
-- The request made will be: @GET /repos/usr/proj/urlSuffix@
gitstarRepoHttp :: UserName
                -> ProjectName
                -> Url
                -> DC (Maybe BsonDocument)
gitstarRepoHttp usr proj urlSuffix = do
  policy <- gitstar
    -- Make sure current user can read:
  mProj  <- findWhere policy $ select [ "name"  =: proj
                                      , "owner" =: usr ] "projects"
  when (".." `isInfixOf` urlSuffix) $ throwIO . userError $
    "gitstarRepoHttp: Path must be fully expanded"
  case mProj of
    Nothing -> return Nothing
    Just Project{} -> do
       let url = gitstar_ssh_web_url ++ "repos/" ++ usr ++ "/"
                                     ++ proj ++ urlSuffix
           req = getRequest url
       sshResp <- mkGitstarHttpReqTCB req L8.empty
       if respStatusDC sshResp /= stat200
         then return Nothing
         else do body <- liftLIO $ extractBody sshResp
                 return . Just . decodeDoc $ body

-- | Send request to create a repository
gitstarCreateRepo :: UserName
                  -> ProjectName
                  -> DC ()
gitstarCreateRepo usr proj = do
  let url = gitstar_ssh_web_url ++ "repos/" ++ usr ++ "/" ++ proj
      req = postRequest url "application/none" L8.empty
  resp <- mkGitstarHttpReqTCB req L8.empty
  unless (respStatusDC resp == stat200) $
    throwIO . userError $ "SSH Web server failure"

-- | Fork project @pid@ to @newUser/newProj@
gitstarForkRepo :: ObjectId
                -> UserName
                -> ProjectName
                -> DC ()
gitstarForkRepo pid newUsr newProj = do
  policy@(GitstarPolicy privs _) <- gitstar
  moproj <- findByP privs policy "projects" "_id" (Just pid)
  case moproj of
    Nothing -> throwIO . userError $ "Project missing"
    Just oproj -> do
      let usr  = projectOwner oproj
          proj = projectName oproj
          body = L8.pack $ "fork_to=/" ++ newUsr ++ "/" ++ newProj
          url  = gitstar_ssh_web_url ++ "repos/" ++ usr ++ "/" ++ proj
          req  = postRequest url "application/x-www-form-urlencoded" body
      resp <- mkGitstarHttpReqTCB req body
      unless (respStatusDC resp == stat200) $
        throwIO . userError $ "SSH Web server failure"

-- | Make empty-body request to the gitstar API server
mkGitstarHttpReqTCB :: HttpReq () -> L8.ByteString -> DC HttpRespDC
mkGitstarHttpReqTCB req0 body = do
  (GitstarPolicy privs _) <- gitstar
  let authHdr = ( S8.pack "authorization"
                , gitstar_ssh_web_authorization)
      acceptHdr = (S8.pack "accept", S8.pack "application/bson")
      req  = req0 {reqHeaders = authHdr: acceptHdr: reqHeaders req0}
  simpleHttpP privs req body

--
-- Misc
--

maybeRead :: Read a => String -> Maybe a
maybeRead = fmap fst . listToMaybe . reads
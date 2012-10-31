{-# LANGUAGE ScopedTypeVariables #-}
module Language.Haskell.Refact.DupDef(duplicateDef, doDuplicateDef) where

import qualified Data.Generics as SYB
import qualified GHC.SYB.Utils as SYB

import qualified Bag                   as GHC
import qualified DynFlags              as GHC
import qualified FastString            as GHC
import qualified GHC
import qualified MonadUtils            as GHC
import qualified OccName               as GHC
import qualified Outputable            as GHC
import qualified RdrName               as GHC

import Control.Monad
import Control.Monad.State
import Data.Data
import Data.List
import Data.Maybe
import GHC.Paths ( libdir )

import Language.Haskell.Refact.Utils
import Language.Haskell.Refact.Utils.GhcUtils
import Language.Haskell.Refact.Utils.LocUtils
import Language.Haskell.Refact.Utils.Monad
import Language.Haskell.Refact.Utils.TypeSyn
import Language.Haskell.Refact.Utils.TypeUtils

-- ---------------------------------------------------------------------
-- | This refactoring duplicates a definition(function binding or
-- simple pattern binding) at same level with a new name provided by
-- the user. The new name should not cause name clash/capture.

-- TODO: This boilerplate will be moved to the coordinator, just comp will be exposed
doDuplicateDef :: [String] -> IO () -- For now
doDuplicateDef args
 = do let fileName = ghead "filename" args
          newName  = args!!1
          row      = read (args!!2)::Int
          col      = read (args!!3)::Int
      duplicateDef Nothing  Nothing fileName newName (row,col)
      return ()

-- | The API entry point
duplicateDef :: Maybe RefactSettings -> Maybe FilePath -> FilePath -> String -> SimpPos -> IO ()
duplicateDef settings maybeMainFile fileName newName (row,col) =
  runRefacSession settings (comp maybeMainFile fileName newName (row,col))


comp :: Maybe FilePath -> FilePath -> String -> SimpPos
     -> RefactGhc [ApplyRefacResult]
comp maybeMainFile fileName newName (row, col) = do
      if isVarId newName
        then do loadModuleGraphGhc maybeMainFile
                modInfo@((_,renamed,parsed), _tokList) <- getModuleGhc fileName
                let (Just (modName,_)) = getModuleName parsed
                let maybePn = locToName (GHC.mkFastString fileName) (row, col) renamed
                case maybePn of
                  Just pn ->
                       -- do refactoredMod@((fileName',m),(tokList',parsed')) <- applyRefac (doDuplicating pn newName) (Just modInfo) fileName
                       do refactoredMod@((fp,ismod),(toks',renamed')) <- applyRefac (doDuplicating pn newName) (Just modInfo) fileName
                          st <- get
                          case (rsStreamModified st) of
                            False -> error "The selected identifier is not a function/simple pattern name, or is not defined in this module "
                            True -> return ()

                          if modIsExported parsed
                           then do clients <- clientModsAndFiles modName
                                   liftIO $ putStrLn ("DupDef: clients=" ++ (GHC.showPpr clients)) -- ++AZ++ debug
                                   refactoredClients <- mapM (refactorInClientMod modName 
                                                             (findNewPName newName renamed')) clients
                                   return $ refactoredMod:refactoredClients
                           else  return [refactoredMod]
                  Nothing -> error "Invalid cursor position!"
        else error $ "Invalid new function name:" ++ newName ++ "!"


doDuplicating :: GHC.Located GHC.Name -> String -> ParseResult
              -> RefactGhc RefactResult
doDuplicating pn newName (inscopes,Just renamed,parsed) =

   everywhereMStaged SYB.Renamer (SYB.mkM dupInMod
                                  `SYB.extM` dupInMatch
                                  `SYB.extM` dupInPat
                                  `SYB.extM` dupInLet
                                  `SYB.extM` dupInLetStmt
                                 ) renamed
        where
        --1. The definition to be duplicated is at top level.
        -- dupInMod :: (GHC.HsGroup GHC.Name)-> RefactGhc (GHC.HsGroup GHC.Name)
        dupInMod (grp :: (GHC.HsGroup GHC.Name))
          | not $ emptyList (findFunOrPatBind pn (hsBinds grp)) = doDuplicating' inscopes grp pn
        dupInMod grp = return grp

        --2. The definition to be duplicated is a local declaration in a match
        dupInMatch (match@(GHC.Match _pats _typ rhs)::GHC.Match GHC.Name)
          | not $ emptyList (findFunOrPatBind pn (hsBinds rhs)) = doDuplicating' inscopes match pn
        dupInMatch match = return match

        --3. The definition to be duplicated is a local declaration in a pattern binding
        dupInPat (pat@(GHC.PatBind _p rhs _typ _fvs _) :: GHC.HsBind GHC.Name)
          | not $ emptyList (findFunOrPatBind pn (hsBinds rhs)) = doDuplicating' inscopes pat pn
        dupInPat pat = return pat

        --4: The defintion to be duplicated is a local decl in a Let expression
        dupInLet (letExp@(GHC.HsLet ds e):: GHC.HsExpr GHC.Name)
          | not $ emptyList (findFunOrPatBind pn (hsBinds ds)) = doDuplicating' inscopes letExp pn
        dupInLet letExp = return letExp

        --5. The definition to be duplicated is a local decl in a case alternative.
        -- Note: The local declarations in a case alternative are covered in #2 above.

        --6.The definition to be duplicated is a local decl in a Let statement.
        dupInLetStmt (letStmt@(GHC.LetStmt ds):: GHC.Stmt GHC.Name)
           -- |findFunOrPatBind pn ds /=[]=doDuplicating' inscps letStmt pn
           |not $ emptyList (findFunOrPatBind pn (hsBinds ds)) = doDuplicating' inscopes letStmt pn
        dupInLetStmt letStmt = return letStmt


        -- findFunOrPatBind :: (SYB.Data t) => GHC.Located GHC.Name -> t -> [GHC.LHsBind GHC.Name]
        findFunOrPatBind (GHC.L _ n) ds = filter (\d->isFunBindR d || isSimplePatBind d) $ definingDeclsNames [n] ds True False


        doDuplicating' :: (HsBinds t) => InScopes -> t -> GHC.Located GHC.Name
                       -> RefactGhc (t)
        doDuplicating' inscps parentr ln@(GHC.L _ n)
           = do let -- decls           = hsDecls parent -- TODO: reinstate this
                    -- declsr = GHC.bagToList $ getDecls parentr
                    declsr = hsBinds parentr

                    duplicatedDecls = definingDeclsNames [n] declsr True False
                    -- (after,before)  = break (definesP pn) (reverse declsp)

                    (f,d) = hsFDNamesFromInside parentr
                    --f: names that might be shadowd by the new name,
                    --d: names that might clash with the new name

                    dv = hsVisibleNames ln declsr --dv: names may shadow new name
                    -- inscpsNames = map ( \(x,_,_,_)-> x) $ inScopeInfo inscps
                    vars        = nub (f `union` d `union` dv)

                newNameGhc <- mkNewName newName
                -- TODO: Where definition is of form tup@(h,t), test each element of it for clashes, or disallow    
                nameAlreadyInScope <- isInScopeAndUnqualifiedGhc newName

                -- liftIO $ putStrLn ("DupDef: nameAlreadyInScope =" ++ (show nameAlreadyInScope)) -- ++AZ++ debug
                liftIO $ putStrLn ("DupDef: ln =" ++ (show ln)) -- ++AZ++ debug
                -- liftIO $ putStrLn ("DupDef: duplicatedDecls =" ++ (GHC.showPpr duplicatedDecls)) -- ++AZ++ debug
                -- liftIO $ putStrLn ("DupDef: duplicatedDecls =" ++ (SYB.showData SYB.Renamer 0 $ duplicatedDecls)) -- ++AZ++ debug
                -- liftIO $ putStrLn ("DupDef: declsr =" ++ (SYB.showData SYB.Renamer 0 $ declsr)) -- ++AZ++ debug

                -- if elem newName vars || (isInScopeAndUnqualified newName inscps && findEntity ln duplicatedDecls) 
                if elem newName vars || (nameAlreadyInScope && findEntity ln duplicatedDecls) 
                   then error ("The new name'"++newName++"' will cause name clash/capture or ambiguity problem after "
                               ++ "duplicating, please select another name!")
                   else do newBinding <- duplicateDecl declsr n newNameGhc
                           -- liftIO $ putStrLn ("DupDef: newBinding =" ++ (GHC.showPpr newBinding)) -- ++AZ++ debug
                           -- liftIO $ putStrLn ("DupDef: declsr =" ++ (GHC.showPpr declsr)) -- ++AZ++ debu

                           -- let newDecls = replaceDecls declsr (reverse before++ newBinding++ reverse after)
                           let newDecls = replaceDecls declsr (declsr ++ newBinding)
                           -- return (GHC.L lp (hsMod {GHC.hsmodDecls = newDecls}))
                           -- return $ g { GHC.hs_valds = (GHC.ValBindsIn (GHC.listToBag newDecls) []) } -- ++AZ++ what about GHC.ValBindsOut?
                           return $ replaceBinds parentr newDecls



-- | Find the the new definition name in GHC.Name format.
findNewPName :: String -> GHC.RenamedSource -> GHC.Name
findNewPName name renamed = fromJust res
  where
     res = somethingStaged SYB.Renamer Nothing
            (Nothing `SYB.mkQ` worker) renamed

     worker  (pname::GHC.Name)
        | (GHC.occNameString $ GHC.getOccName pname) == name = Just pname
     worker _ = Nothing

-- Do refactoring in the client module.
-- That is to hide the identifer in the import declaration if it will
-- cause any problem in the client module.

refactorInClientMod :: GHC.ModuleName -> GHC.Name -> GHC.ModSummary
                    -> RefactGhc ApplyRefacResult
refactorInClientMod serverModName newPName modSummary
  = do
       let fileName = fromJust $ GHC.ml_hs_file $ GHC.ms_location modSummary
       modInfo@((_inscopes,Just renamed,parsed),ts) <- getModuleGhc fileName
       let modNames = willBeUnQualImportedBy serverModName renamed
       -- if isJust modNames && needToBeHided (pNtoName newPName) exps parsed
       mustHide <- needToBeHided newPName renamed
       if isJust modNames && mustHide
        -- then do (parsed', ((ts',m),_))<-runStateT (addHiding serverModName parsed [newPName]) ((ts,unmodified),fileName)
        -- then do refactoredMod <- applyRefac (addHiding serverModName parsed [newPName]) (Just modInfo) fileName
        then do refactoredMod <- applyRefac (doDuplicatingClient serverModName [newPName]) (Just modInfo) fileName
                return refactoredMod
        else return ((fileName,unmodified),(ts,renamed))
   where
     needToBeHided :: GHC.Name -> GHC.RenamedSource -> RefactGhc Bool
     needToBeHided name exps = do
         usedUnqal <- usedWithoutQual name exps
         return $ usedUnqal || causeNameClashInExports name serverModName exps



doDuplicatingClient :: GHC.ModuleName -> [GHC.Name] -> ParseResult
              -> RefactGhc RefactResult
doDuplicatingClient serverModName newPNames (inscopes,Just renamed,parsed) = do
  renamed' <- addHiding serverModName renamed newPNames
  return renamed'

{-
--Do refactoring in the client module.
-- that is to hide the identifer in the import declaration if it will cause any problem in the client module.
refactorInClientMod serverModName newPName (modName, fileName)
  = do (inscps, exps,parsed ,ts) <- parseSourceFile fileName
       let modNames = willBeUnQualImportedBy serverModName parsed
       if isJust modNames && needToBeHided (pNtoName newPName) exps parsed
        then do (parsed', ((ts',m),_))<-runStateT (addHiding serverModName parsed [newPName]) ((ts,unmodified),fileName)
                return ((fileName,m), (ts',parsed'))
        else return ((fileName,unmodified),(ts,parsed))
   where
     needToBeHided name exps parsed
         =usedWithoutQual name (hsModDecls parsed)
          || causeNameClashInExports newPName name parsed exps
-}



--Check here:
-- | get the module name or alias name by which the duplicated
-- definition will be imported automatically.
willBeUnQualImportedBy :: GHC.ModuleName -> GHC.RenamedSource -> Maybe [GHC.ModuleName]
willBeUnQualImportedBy modName renamed@(_,imps,_,_)
   = let
         ms = filter (\(GHC.L _ (GHC.ImportDecl (GHC.L _ modName1) qualify _source _safe isQualified _isImplicit as h))
                    -> modName == modName1
                       && not isQualified
                              && (isNothing h  -- not hiding
                                  ||
                                   (isJust h && ((fst (fromJust h))==True))
                                  ))
                      imps
         in if (emptyList ms) then Nothing
                      else Just $ nub $ map getModName ms

         where getModName (GHC.L _ (GHC.ImportDecl modName1 qualify _source _safe isQualified _isImplicit as h))
                 = if isJust as then (fromJust as)
                                else modName
               -- simpModName (SN m loc) = m

{- ++AZ++ original
--Check here:
--get the module name or alias name by which the duplicated definition will be imported automatically.
willBeUnQualImportedBy::HsName.ModuleName->HsModuleP->Maybe [HsName.ModuleName]
willBeUnQualImportedBy modName parsed
   = let imps = hsModImports parsed
         ms   = filter (\(HsImportDecl _ (SN modName1 _) qualify  as h)->modName==modName1 && (not qualify) && 
                          (isNothing h || (isJust h && ((fst (fromJust h))==True)))) imps
         in if ms==[] then Nothing
                      else Just $ nub $ map getModName ms

         where getModName (HsImportDecl _ (SN modName _) qualify  as h)
                 = if isJust as then simpModName (fromJust as)
                                else modName
               simpModName (SN m loc) = m

-}
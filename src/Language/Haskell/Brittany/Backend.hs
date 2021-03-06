{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeApplications #-}

module Language.Haskell.Brittany.Backend
  ( layoutBriDocM
  )
where



#include "prelude.inc"

import qualified Language.Haskell.GHC.ExactPrint as ExactPrint
import qualified Language.Haskell.GHC.ExactPrint.Annotate as ExactPrint.Annotate
import qualified Language.Haskell.GHC.ExactPrint.Types as ExactPrint.Types
import           Language.Haskell.GHC.ExactPrint.Types ( AnnKey, Annotation )

import           Language.Haskell.Brittany.LayouterBasics
import           Language.Haskell.Brittany.BackendUtils
import           Language.Haskell.Brittany.Utils
import           Language.Haskell.Brittany.Config.Types
import           Language.Haskell.Brittany.Types


import qualified Data.Text.Lazy.Builder as Text.Builder


import           Data.HList.ContainsType

import           Control.Monad.Extra ( whenM )

import qualified Control.Monad.Trans.Writer.Strict as WriterS



briDocLineLength :: BriDoc -> Int
briDocLineLength briDoc = flip StateS.evalState False $ rec briDoc
                          -- the state encodes whether a separate was already
                          -- appended at the current position.
 where
  rec = \case
    BDEmpty                 -> return $ 0
    BDLit t                 -> StateS.put False $> Text.length t
    BDSeq bds               -> sum <$> rec `mapM` bds
    BDCols _ bds            -> sum <$> rec `mapM` bds
    BDSeparator -> StateS.get >>= \b -> StateS.put True $> if b then 0 else 1
    BDAddBaseY _ bd         -> rec bd
    BDBaseYPushCur       bd -> rec bd
    BDBaseYPop           bd -> rec bd
    BDIndentLevelPushCur bd -> rec bd
    BDIndentLevelPop     bd -> rec bd
    BDPar _ line _          -> rec line
    BDAlt{}                 -> error "briDocLineLength BDAlt"
    BDForceMultiline  bd    -> rec bd
    BDForceSingleline bd    -> rec bd
    BDForwardLineMode bd    -> rec bd
    BDExternal _ _ _ t      -> return $ Text.length t
    BDAnnotationPrior _ bd  -> rec bd
    BDAnnotationKW _ _ bd   -> rec bd
    BDAnnotationRest _ bd   -> rec bd
    BDLines ls@(_:_)        -> do
      x <- StateS.get
      return $ maximum $ ls <&> \l -> StateS.evalState (rec l) x
    BDLines []              -> error "briDocLineLength BDLines []"
    BDEnsureIndent _ bd     -> rec bd
    BDProhibitMTEL     bd   -> rec bd
    BDSetParSpacing    bd   -> rec bd
    BDForceParSpacing  bd   -> rec bd
    BDNonBottomSpacing bd   -> rec bd
    BDDebug _ bd            -> rec bd

layoutBriDocM
  :: forall w m
   . ( m ~ MultiRWSS.MultiRWST
             '[Config, ExactPrint.Anns]
             w
             '[LayoutState]
             Identity
     , ContainsType Text.Builder.Builder w
     , ContainsType [LayoutError] w
     , ContainsType (Seq String) w
     )
  => BriDoc
  -> m ()
layoutBriDocM = \case
  BDEmpty -> do
    return () -- can it be that simple
  BDLit t -> do
    layoutIndentRestorePostComment
    layoutRemoveIndentLevelLinger
    layoutWriteAppend t
  BDSeq list -> do
    list `forM_` layoutBriDocM
  -- in this situation, there is nothing to do about cols.
  -- i think this one does not happen anymore with the current simplifications.
  -- BDCols cSig list | BDPar sameLine lines <- List.last list ->
  --   alignColsPar $ BDCols cSig (List.init list ++ [sameLine]) : lines
  BDCols _ list -> do
    list `forM_` layoutBriDocM
  BDSeparator -> do
    layoutAddSepSpace
  BDAddBaseY indent bd -> do
    let indentF = case indent of
          BrIndentNone      -> id
          BrIndentRegular   -> layoutWithAddBaseCol
          BrIndentSpecial i -> layoutWithAddBaseColN i
    indentF $ layoutBriDocM bd
  BDBaseYPushCur bd -> do
    layoutBaseYPushCur
    layoutBriDocM bd
  BDBaseYPop bd -> do
    layoutBriDocM bd
    layoutBaseYPop
  BDIndentLevelPushCur bd -> do
    layoutIndentLevelPushCur
    layoutBriDocM bd
  BDIndentLevelPop bd -> do
    layoutBriDocM bd
    layoutIndentLevelPop
  BDEnsureIndent indent bd -> do
    let indentF = case indent of
          BrIndentNone      -> id
          BrIndentRegular   -> layoutWithAddBaseCol
          BrIndentSpecial i -> layoutWithAddBaseColN i
    indentF $ do
      layoutWriteEnsureBlock
      layoutBriDocM bd
  BDPar indent sameLine indented -> do
    layoutBriDocM sameLine
    let indentF = case indent of
          BrIndentNone      -> id
          BrIndentRegular   -> layoutWithAddBaseCol
          BrIndentSpecial i -> layoutWithAddBaseColN i
    indentF $ do
      layoutWriteNewlineBlock
      layoutBriDocM indented
  BDLines lines ->
    alignColsLines lines
  BDAlt [] -> error "empty BDAlt"
  BDAlt (alt:_) -> layoutBriDocM alt
  BDForceMultiline  bd -> layoutBriDocM bd
  BDForceSingleline bd -> layoutBriDocM bd
  BDForwardLineMode bd -> layoutBriDocM bd
  BDExternal annKey subKeys shouldAddComment t -> do
    let tlines = Text.lines $ t <> Text.pack "\n"
        tlineCount = length tlines
    anns :: ExactPrint.Anns <- mAsk
    when shouldAddComment $ do
      layoutWriteAppend $ Text.pack $ "{-" ++ show (annKey, Map.lookup annKey anns) ++ "-}"
    zip [1..] tlines `forM_` \(i, l) -> do
      layoutWriteAppend $ l
      unless (i==tlineCount) layoutWriteNewlineBlock
    do
      state <- mGet
      let filterF k _ = not $ k `Set.member` subKeys
      mSet $ state
        { _lstate_comments = Map.filterWithKey filterF
                           $ _lstate_comments state
        }
  BDAnnotationPrior annKey bd -> do
    state <- mGet
    let m   = _lstate_comments state
    let allowMTEL = not (_lstate_inhibitMTEL state)
                 && Data.Either.isRight (_lstate_curYOrAddNewline state)
    mAnn <- do
      let mAnn = ExactPrint.annPriorComments <$> Map.lookup annKey m
      mSet $ state
       { _lstate_comments =
           Map.adjust (\ann -> ann { ExactPrint.annPriorComments = [] }) annKey m
       }
      return mAnn
    case mAnn of
      Nothing -> when allowMTEL $ moveToExactAnn annKey
      Just [] -> when allowMTEL $ moveToExactAnn annKey
      Just priors -> do
        -- layoutResetSepSpace
        priors `forM_` \( ExactPrint.Types.Comment comment _ _
                        , ExactPrint.Types.DP (y, x)
                        ) -> do
          -- evil hack for CPP:
          case comment of
            ('#':_) -> layoutMoveToCommentPos y (-999)
            _       -> layoutMoveToCommentPos y x
          -- fixedX <- fixMoveToLineByIsNewline x
          -- replicateM_ fixedX layoutWriteNewline
          -- layoutMoveToIndentCol y
          layoutWriteAppendMultiline $ Text.pack $ comment
          -- mModify $ \s -> s { _lstate_curYOrAddNewline = Right 0 }
        when allowMTEL $ moveToExactAnn annKey
    layoutBriDocM bd
  BDAnnotationKW annKey keyword bd -> do
    layoutBriDocM bd
    mAnn <- do
      state <- mGet
      let m   = _lstate_comments state
      let mAnn = ExactPrint.annsDP <$> Map.lookup annKey m
      let mToSpan = case mAnn of
            Just anns | keyword==Nothing -> Just anns
            Just ((ExactPrint.Types.G kw1, _):annR)
              | keyword==Just kw1        -> Just annR
            _                            -> Nothing
      case mToSpan of
        Just anns -> do
          let (comments, rest) = flip spanMaybe anns $ \case
                (ExactPrint.Types.AnnComment x, dp) -> Just (x, dp)
                _ -> Nothing
          mSet $ state
            { _lstate_comments =
                Map.adjust (\ann -> ann { ExactPrint.annsDP = rest })
                           annKey
                           m
            }
          return $ [ comments | not $ null comments ]
        _ -> return Nothing
    forM_ mAnn $ mapM_ $ \( ExactPrint.Types.Comment comment _ _
                          , ExactPrint.Types.DP (y, x)
                          ) -> do
      -- evil hack for CPP:
      case comment of
        ('#':_) -> layoutMoveToCommentPos y (-999)
        _       -> layoutMoveToCommentPos y x
      -- fixedX <- fixMoveToLineByIsNewline x
      -- replicateM_ fixedX layoutWriteNewline
      -- layoutMoveToIndentCol y
      layoutWriteAppendMultiline $ Text.pack $ comment
      -- mModify $ \s -> s { _lstate_curYOrAddNewline = Right 0 }
  BDAnnotationRest annKey bd -> do
    layoutBriDocM bd
    mAnn <- do
      state <- mGet
      let m   = _lstate_comments state
      let mAnn = extractAllComments <$> Map.lookup annKey m
      mSet $ state
        { _lstate_comments =
            Map.adjust (\ann -> ann { ExactPrint.annFollowingComments = []
                                    , ExactPrint.annPriorComments = []
                                    , ExactPrint.annsDP = []
                                    }
                       )
                       annKey
                       m
        }
      return mAnn
    forM_ mAnn $ mapM_ $ \( ExactPrint.Types.Comment comment _ _
                          , ExactPrint.Types.DP (y, x)
                          ) -> do
      -- evil hack for CPP:
      case comment of
        ('#':_) -> layoutMoveToCommentPos y (-999)
        _       -> layoutMoveToCommentPos y x
      -- fixedX <- fixMoveToLineByIsNewline x
      -- replicateM_ fixedX layoutWriteNewline
      -- layoutMoveToIndentCol y
      layoutWriteAppendMultiline $ Text.pack $ comment
      -- mModify $ \s -> s { _lstate_curYOrAddNewline = Right 0 }
  BDNonBottomSpacing bd -> layoutBriDocM bd
  BDSetParSpacing bd -> layoutBriDocM bd
  BDForceParSpacing bd -> layoutBriDocM bd
  BDProhibitMTEL bd -> do
    -- set flag to True for this child, but disable afterwards.
    -- two hard aspects
    -- 1) nesting should be allowed. this means that resetting at the end must
    --    not indiscriminantely set to False, but take into account the
    --    previous value
    -- 2) nonetheless, newlines cancel inhibition. this means that if we ever
    --    find the flag set to False afterwards, we must not return it to
    --    the previous value, which might be True in the case of testing; it
    --    must remain False.
    state <- mGet
    mSet $ state { _lstate_inhibitMTEL = True }
    layoutBriDocM bd
    state' <- mGet
    when (_lstate_inhibitMTEL state') $ do
      mSet $ state' { _lstate_inhibitMTEL = _lstate_inhibitMTEL state }
  BDDebug s bd -> do
    mTell $ Text.Builder.fromText $ Text.pack $ "{-" ++ s ++ "-}"
    layoutBriDocM bd
  where
    -- alignColsPar :: [BriDoc]
    --           -> m ()
    -- alignColsPar l = colInfos `forM_` \colInfo -> do
    --     layoutWriteNewlineBlock
    --     processInfo (_cbs_map finalState) colInfo
    --   where
    --     (colInfos, finalState) = StateS.runState (mergeBriDocs l) (ColBuildState IntMapS.empty 0)
    alignColsLines :: [BriDoc]
              -> m ()
    alignColsLines bridocs = do -- colInfos `forM_` \colInfo -> do
      curX <- do
        state <- mGet
        return $ either id (const 0) (_lstate_curYOrAddNewline state)
               + fromMaybe 0 (_lstate_addSepSpace state)
      colMax    <- mAsk <&> _conf_layout .> _lconfig_cols .> confUnpack
      sequence_ $ List.intersperse layoutWriteEnsureNewlineBlock
                $ colInfos <&> processInfo (processedMap curX colMax)
      where
        (colInfos, finalState) = StateS.runState (mergeBriDocs bridocs)
                                                 (ColBuildState IntMapS.empty 0)
        maxZipper :: [Int] -> [Int] -> [Int]
        maxZipper [] ys = ys
        maxZipper xs [] = xs
        maxZipper (x:xr) (y:yr) = max x y : maxZipper xr yr
        processedMap :: Int -> Int -> ColMap2
        processedMap curX colMax = fix $ \result ->
          _cbs_map finalState <&> \(lastFlag, colSpacingss) ->
            let colss = colSpacingss <&> \spss -> case reverse spss of
                  [] -> []
                  (xN:xR) -> reverse
                    $ (if lastFlag then fLast else fInit) xN : fmap fInit xR
                  where
                    fLast (ColumnSpacingLeaf len)  = len
                    fLast (ColumnSpacingRef len _) = len
                    fInit (ColumnSpacingLeaf len) = len
                    fInit (ColumnSpacingRef _ i) = case IntMapL.lookup i result of
                      Nothing           -> 0
                      Just (_, maxs, _) -> sum maxs
                maxCols = Foldable.foldl1 maxZipper colss
                (_, posXs) = mapAccumL (\acc x -> (acc+x,acc)) curX maxCols
                counter count l =
                  if List.last posXs + List.last l <=colMax
                    then count + 1
                    else count
                ratio = fromIntegral (foldl counter (0::Int) colss)
                      / fromIntegral (length colss)
            in  (ratio, maxCols, colss)
    briDocToColInfo :: Bool -> BriDoc -> StateS.State ColBuildState ColInfo
    briDocToColInfo lastFlag = \case
      BDCols sig list -> withAlloc lastFlag $ \ind -> do
        let isLastList =
              if lastFlag then (== length list) <$> [1..] else repeat False
        subInfos <- zip isLastList list `forM` uncurry briDocToColInfo
        let lengthInfos = zip (briDocLineLength <$> list) subInfos
        let trueSpacings = getTrueSpacings lengthInfos
        return $ (Seq.singleton trueSpacings, ColInfo ind sig lengthInfos)
      bd -> return $ ColInfoNo bd

    getTrueSpacings :: [(Int, ColInfo)] -> [ColumnSpacing]
    getTrueSpacings lengthInfos = lengthInfos <&> \case
      (len, ColInfo i _ _) -> ColumnSpacingRef len i
      (len, _)              -> ColumnSpacingLeaf len

    mergeBriDocs :: [BriDoc] -> StateS.State ColBuildState [ColInfo]
    mergeBriDocs bds = mergeBriDocsW ColInfoStart bds

    mergeBriDocsW :: ColInfo -> [BriDoc] -> StateS.State ColBuildState [ColInfo]
    mergeBriDocsW _ [] = return []
    mergeBriDocsW lastInfo (bd:bdr) = do
      info <- mergeInfoBriDoc True lastInfo bd
      infor <- mergeBriDocsW info bdr
      return $ info : infor

    mergeInfoBriDoc :: Bool
                    -> ColInfo
                    -> BriDoc
                    -> StateS.StateT ColBuildState Identity ColInfo
    mergeInfoBriDoc lastFlag ColInfoStart = briDocToColInfo lastFlag
    mergeInfoBriDoc lastFlag ColInfoNo{}  = briDocToColInfo lastFlag
    mergeInfoBriDoc lastFlag (ColInfo infoInd infoSig subLengthsInfos) = \case
      brdc@(BDCols colSig subDocs)
        | infoSig == colSig
        && length subLengthsInfos == length subDocs -> do
          let isLastList =
                if lastFlag then (== length subDocs) <$> [1..] else repeat False
          infos <- zip3 isLastList (snd <$> subLengthsInfos) subDocs
            `forM` \(lf, info, bd) -> mergeInfoBriDoc lf info bd
          let curLengths = briDocLineLength <$> subDocs
          let trueSpacings = getTrueSpacings (zip curLengths infos)
          do -- update map
            s <- StateS.get
            let m = _cbs_map s
            let (Just (_, spaces)) = IntMapS.lookup infoInd m
            StateS.put s
              { _cbs_map = IntMapS.insert infoInd
                                          (lastFlag, spaces Seq.|> trueSpacings)
                                          m
              }
          return $ ColInfo infoInd colSig (zip curLengths infos)
        | otherwise -> briDocToColInfo lastFlag brdc
      brdc          -> return $ ColInfoNo brdc
    
    withAlloc :: Bool
              -> (ColIndex -> StateS.State ColBuildState (ColumnBlocks ColumnSpacing, ColInfo))
              -> StateS.State ColBuildState ColInfo
    withAlloc lastFlag f = do
      cbs <- StateS.get
      let ind = _cbs_index cbs
      StateS.put $ cbs { _cbs_index = ind + 1 }
      (space, info) <- f ind
      StateS.get >>= \c -> StateS.put
        $ c { _cbs_map = IntMapS.insert ind (lastFlag, space) $ _cbs_map c }
      return info

    processInfo :: ColMap2 -> ColInfo -> m ()
    processInfo m = \case
      ColInfoStart -> error "should not happen (TM)"
      ColInfoNo doc -> layoutBriDocM doc
      ColInfo ind _ list -> do
        colMax    <- mAsk <&> _conf_layout .> _lconfig_cols .> confUnpack
        alignMode <- mAsk <&> _conf_layout .> _lconfig_columnAlignMode .> confUnpack
        curX <- do
          state <- mGet
          return $ either id (const 0) (_lstate_curYOrAddNewline state)
                 + fromMaybe 0 (_lstate_addSepSpace state)
        -- tellDebugMess $ show curX
        let Just (ratio, maxCols, _colss) = IntMapS.lookup ind m
        let (maxX, posXs) = mapAccumL (\acc x -> (acc+x,acc)) curX maxCols
        -- handle the cases that the vertical alignment leads to more than max
        -- cols:
        -- this is not a full fix, and we must correct individually in addition.
        -- because: the (at least) line with the largest element in the last
        -- column will always still overflow, because we just updated the column
        -- sizes in such a way that it works _if_ we have sizes (*factor)
        -- in each column. but in that line, in the last column, we will be
        -- forced to occupy the full vertical space, not reduced by any factor.
        let fixedPosXs = case alignMode of
              ColumnAlignModeAnimouslyScale i | maxX>colMax -> fixed <&> (+curX)
                where
                  factor :: Float = 
                    -- 0.0001 as an offering to the floating point gods.
                    min 1.0001 ( fromIntegral (i + colMax - curX)
                               / fromIntegral (maxX - curX)
                               )
                  offsets = (subtract curX) <$> posXs
                  fixed = offsets <&> fromIntegral .> (*factor) .> truncate
              _ -> posXs
        let alignAct = zip fixedPosXs list `forM_` \(destX, x) -> do
              layoutWriteEnsureAbsoluteN destX
              processInfo m (snd x)
            noAlignAct = list `forM_` (snd .> processInfoIgnore)
            animousAct =
              -- per-item check if there is overflowing.
              if List.last fixedPosXs + fst (List.last list) > colMax
                then noAlignAct
                else alignAct
        case alignMode of
          ColumnAlignModeDisabled                      -> noAlignAct
          ColumnAlignModeUnanimously | maxX<=colMax    -> alignAct
          ColumnAlignModeUnanimously                   -> noAlignAct
          ColumnAlignModeMajority limit | ratio>=limit -> animousAct
          ColumnAlignModeMajority{}                    -> noAlignAct
          ColumnAlignModeAnimouslyScale{}              -> animousAct
          ColumnAlignModeAnimously                     -> animousAct
          ColumnAlignModeAlways                        -> alignAct
    processInfoIgnore :: ColInfo -> m ()
    processInfoIgnore = \case
      ColInfoStart -> error "should not happen (TM)"
      ColInfoNo doc -> layoutBriDocM doc
      ColInfo _ _ list -> list `forM_` (snd .> processInfoIgnore)

type ColIndex  = Int

data ColumnSpacing
  = ColumnSpacingLeaf Int
  | ColumnSpacingRef Int Int

type ColumnBlock  a = [a]
type ColumnBlocks a = Seq [a]
type ColMap1 = IntMapL.IntMap {- ColIndex -} (Bool, ColumnBlocks ColumnSpacing)
type ColMap2 = IntMapL.IntMap {- ColIndex -} (Float, ColumnBlock Int, ColumnBlocks Int)
                                          -- (ratio of hasSpace, maximum, raw)

data ColInfo
  = ColInfoStart -- start value to begin the mapAccumL.
  | ColInfoNo BriDoc
  | ColInfo ColIndex ColSig [(Int, ColInfo)]

instance Show ColInfo where
  show ColInfoStart = "ColInfoStart"
  show ColInfoNo{} = "ColInfoNo{}"
  show (ColInfo ind sig list) = "ColInfo " ++ show ind ++ " " ++ show sig ++ " " ++ show list

data ColBuildState = ColBuildState
  { _cbs_map :: ColMap1
  , _cbs_index :: ColIndex
  }

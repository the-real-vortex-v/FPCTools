program fpctools;

{$mode objfpc}{$H+}

uses
SysUtils, Classes, StrUtils, Math;

const
EXIT_BIT_SYNTAX     = 1;
EXIT_BIT_STRUCTURAL = 2;
EXIT_BIT_UNIMPL     = 4;
EXIT_BIT_INCLUDE    = 8;
EXIT_BIT_WARNING    = 16;

FPCAUDIT_VERSION        = '2.9.2';

FPCAUDIT_PARSER_VERSION = 2;
JSON_SCHEMA_VERSION     = 1;

CACHE_MAGIC         = 'FPAUDIT_CACHE_V23';
CACHE_FILENAME      = '.fpaudit.cache';

type
TIntArray = array of Integer;
TStringArray = array of string;
TBoolArray = array of Boolean;

TTokenKind = (
tkEOF,
tkIdent,
tkSymbol,
tkString,
tkNumber,
tkDirective,
tkLexError
);

TRawToken = record
Kind: TTokenKind;
Text: string;
Lower: string;
Line: Integer;
Col: Integer;
end;
TRawTokenArray = array of TRawToken;

TCommentInfo = record
  Next: Integer;
  FileIdx: Integer;
  Line: Integer;
  Col: Integer;
  Kind: string;  // '//', '{}', '(**)'


  Text: string;
end;
TCommentInfoArray = array of TCommentInfo;

TCommentFileIndex = record
  FileIdx: Integer;
  StartIdx: Integer;
  Count: Integer;
end;
TCommentFileIndexArray = array of TCommentFileIndex;

{ A token with its source file - used for merged (include-aware) scanning }
TMergedToken = record
  FileIdx: Integer;
  Line, Col: Integer;
  Kind: TTokenKind;
  Text, Lower: string;
end;
TMergedTokenArray = array of TMergedToken;

TFileInfo = record
FilePath: string;
DisplayName: string;
IncludedFromFile: Integer;
IncludedFromLine: Integer;
FileSize: Int64;
FileMTime: Int64;
Lines: TStringArray;
Tokens: TRawTokenArray;
Comments: TCommentInfoArray;
LineOffsets: TIntArray;
end;
TFileInfoArray = array of TFileInfo;

TTreeEdge = record
ParentFileIdx: Integer;
ParentLine: Integer;
EdgeKind: string;
TargetDisplay: string;
TargetFileIdx: Integer;
InsideRoutine: string;
AlreadyIncluded: Boolean;
Resolution: string;
end;
TTreeEdgeArray = array of TTreeEdge;

TLocationInfo = record
Valid: Boolean;
Desc: string;
FileIdx: Integer;
Line: Integer;
Col: Integer;
Snippet: string;
end;

TDiagnostic = record
FileIdx: Integer;
Line: Integer;
Col: Integer;
CategoryBit: Integer;
Message: string;
Snippet: string;
ExtraLabel: string;
ExtraSnippet: string;
LastGoodBlock: TLocationInfo;
LastGoodStmt: TLocationInfo;
end;
TDiagnosticArray = array of TDiagnostic;

TUsageSite = record
FileIdx: Integer;
Line: Integer;
end;
TUsageSiteArray = array of TUsageSite;

TUsageItem = record
Name: string;
Detail: string;
Sites: TUsageSiteArray;
end;
TUsageItemArray = array of TUsageItem;

TMemberItem = record
Name: string;
Detail: string;
ValueExpr: string;
IsConst: Boolean;
FileIdx: Integer;
Line: Integer;
end;
TMemberItemArray = array of TMemberItem;

TTypeDecl = record
Name: string;
Kind: string;
FileIdx: Integer;
StartLine: Integer;
EndLine: Integer;
IsForward: Boolean;
Fields: TMemberItemArray;
Methods: TMemberItemArray;
end;
TTypeDeclArray = array of TTypeDecl;

TForwardDecl = record
Name: string;
Kind: string;
Signature: string;
FileIdx: Integer;
Line: Integer;
RequiresImpl: Boolean;
ImplFileIdx: Integer;
ImplLine: Integer;
end;
TForwardDeclArray = array of TForwardDecl;

TRoutineInfo = record
Name: string;
Kind: string;
ReturnType: string;
FileIdx: Integer;
StartLine: Integer;
EndFileIdx: Integer;
EndLine: Integer;
RootBlockIdx: Integer;
Includes: TUsageItemArray;
Params: TUsageItemArray;
Locals: TUsageItemArray;
Assigns: TUsageItemArray;
Vars: TUsageItemArray;
Calls: TUsageItemArray;
end;
TRoutineInfoArray = array of TRoutineInfo;

TLogicBlockKind = (
bkRoutine,
bkType,
bkBegin,
bkIf,
bkElse,
bkFor,
bkWhile,
bkRepeat,
bkCase,
bkTry,
bkExcept,
bkFinally,
bkWith,
bkAsm,
{ Container/coverage kinds (prototype): structural/source-span containers }
bkUnitSection,      { program/unit/library header + global uses/preamble }
bkDeclSection,      { const/var/type/resourcestring/threadvar declaration section }
bkForwardDecl,      { forward/interface routine declaration stub }
bkInitBlock,        { initialization / finalization entry body }
bkGap               { uncovered lines between modeled containers }
);

TLogicBlock = record
Id: Integer;
Kind: TLogicBlockKind;
LabelText: string;
OwnerRoutineIdx: Integer;
ParentIdx: Integer;
Depth: Integer;
FileIdx: Integer;
StartLine: Integer;
EndFileIdx: Integer;
EndLine: Integer;
Children: TIntArray;
end;
TLogicBlockArray = array of TLogicBlock;

TBracketItem = record
TokenText: string;
FileIdx: Integer;
Line: Integer;
Col: Integer;
Snippet: string;
end;
TBracketItemArray = array of TBracketItem;

TCondIfItem = record
Directive: string;
SeenElse: Boolean;
Taken: Boolean;
Active: Boolean;
FileIdx: Integer;
Line: Integer;
Col: Integer;
Snippet: string;
end;
TCondIfItemArray = array of TCondIfItem;

TReportSections = record
ShowTree: Boolean;
ShowBlockTree: Boolean;
ShowDiag: Boolean;
ShowFiles: Boolean;
ShowTypes: Boolean;
ShowGlobals: Boolean;
ShowForwards: Boolean;
ShowRoutines: Boolean;
ShowAssigns: Boolean;
ShowCalls: Boolean;
ShowVars: Boolean;
end;

TSearchHit = record
FileIdx: Integer;
StartLine: Integer;
EndLine: Integer;
Col: Integer;
Snippet: string;
end;
TSearchHitArray = array of TSearchHit;

TCallerHit = record
CallerRoutine: string;
FileIdx: Integer;
Line: Integer;
CallText: string;
end;
TCallerHitArray = array of TCallerHit;

TBlockMatch = record
Found: Boolean;
BlockIdx: Integer;
MatchFileIdx: Integer;
MatchLine: Integer;
MatchSnippet: string;
FromToken: Boolean;
end;

  TStmtSpan = record
    FileIdx: Integer;
    StartLine: Integer;
    StartCol: Integer;
    EndLine: Integer;
    EndCol: Integer;
  end;
  TStmtSpanArray = array of TStmtSpan;

  TGlobalStmtInfo = record
    FileIdx: Integer;
    StartLine: Integer;
    StartCol: Integer;
    EndLine: Integer;
    EndCol: Integer;
    GlobalLine: Integer;
    LineOrdinal: Integer;
    BlockIdx: Integer;
    StmtIdx: Integer;
    Path: string;
    SemanticPath: string;
    Inactive: Boolean;
    Context: string;
    Text: string;
  end;
  TGlobalStmtInfoArray = array of TGlobalStmtInfo;


TForwardInfo = record
Name: string;
Signature: string;
LineNum: Integer;
HasImpl: Boolean;
ImplLine: Integer;
ImplSignature: string;
ImpCount: Integer;
end;
TForwardInfoArray = array of TForwardInfo;

TImplInfo = record
Name: string;
Signature: string;
LineNum: Integer;
  HasForward: Boolean;
  NeedsFwd: Boolean;
end;
TImplInfoArray = array of TImplInfo;

TProvenanceEntry = record
SymbolName: string;
KindLabel: string;
Detail: string;
FileIdx: Integer;
Line: Integer;
NavHint: string;
end;
TProvenanceEntryArray = array of TProvenanceEntry;

TAuditState = record
Files: TFileInfoArray;
TreeEdges: TTreeEdgeArray;
Diags: TDiagnosticArray;
Types: TTypeDeclArray;
Globals: TMemberItemArray;
Forwards: TForwardDeclArray;
Routines: TRoutineInfoArray;
LogicBlocks: TLogicBlockArray;
end;

{ Orchestration options snapshot - the flag-driven pipeline contract }
  TAppOptions = record
    CheckOnly: Boolean;
    StrictMode: Boolean;
    JsonMode: Boolean;
    SarifMode: Boolean;
    DiffMode: Boolean;
    DryRunMode: Boolean;
    VerifyMode: Boolean;
    FixForward: Boolean;
    CheckForward: Boolean;
    FixAll: Boolean;
    AddForward: Boolean;
    AddInclude: Boolean;
    AddBlock: Boolean;
    ReadFullMode: string;
    ReadFullLine: Integer;
    FilterPattern: string;
    SearchInTarget: string;
    ScopeBlockIdx: Integer;
    GetBlockMode: Boolean;
    GetBlockTarget: string;
    GetBlockWithOrigin: Boolean;
    GetBlockStandalone: Boolean;
    GlobalLinesMode: Boolean;
    GlobalLineMode: Boolean;
    GlobalStmtsMode: Boolean;
    DecodeGSLineMode: Boolean;
    LineToGSMode: Boolean;
    GlobalLinesSpec: string;
    GlobalLineNum: Integer;
    OutFile: string;
    TargetFile: string;
    OutlineMode: Boolean;
    EditPlanTarget: string;
    EditPlanSpecified: Boolean;
    OutputRawMode: Boolean;
    InsertBeforeTarget: string;
    InsertAfterTarget: string;
    InsertFilePath: string;
    InsertFileBeforeTarget: string;
    InsertFileAfterTarget: string;
    BeforeTarget: string;
    AfterTarget: string;
    DeleteTarget: string;
    ReplaceTarget: string;
    ReplaceText: string;
    InsertLoc: string;
    InsertText: string;
    DoDelete: Boolean;
    DoReplace: Boolean;
    DoInsert: Boolean;
    BlockEditMode: Boolean;
    BlockEditTarget: string;
    BlockEditMatch: string;
    BlockEditReplacement: string;
    GlobalEditMode: Boolean;
    GlobalDeleteMode: Boolean;
    StmtListMode: Boolean;
    StmtListTarget: string;
    StmtEditMode: Boolean;
    StmtEditTarget: string;
    StmtEditIndex: Integer;
    StmtEditAction: string;
    StmtEditText: string;

    EditGLineMode: Boolean;
    DeleteGLineMode: Boolean;
    EditGLineNum: Integer;
    EditFileIdx: Integer;
    NoCacheMode: Boolean;
    ClearCacheMode: Boolean;
    ShowByteOffsets: Boolean;
    LazarusProject: string;
    UnitsMode: Boolean;
    ReportFilterSet: Boolean;
    ReportOpts: TReportSections;
    FindPattern: string;
    CallersTarget: string;
    OrphansMode: Boolean;
    ShowRoutineTarget: string;
    LinesSliceSpec: string;
    SearchPattern: string;
    GiveBlockNum: Integer;
    GiveBlockSpecified: Boolean;
    BlockChunkSize: Integer;
    BlockSizeSpecified: Boolean;
    WidenBlockSteps: Integer;
    MaxTreeDepth: Integer;
    HideVars: Boolean;
    HideFuncs: Boolean;
    HideBlocks: Boolean; FixIndentMode: Boolean; IndentSize: Integer;

  end;



var
State: TAuditState;
  Options: TAppOptions;
IncPaths: TStringArray;
Brackets: TBracketItemArray;
  AllComments: TCommentInfoArray;
  CommentHead: Integer;
  CommentTail: Integer;
CurLexFile: Integer;
  CommentIndex: TCommentFileIndexArray;
CondStack: TCondIfItemArray;
DefineNames: TStringArray;
LastGoodBlock: TLocationInfo;
LastGoodStmt: TLocationInfo;

{ CLI Flags }
TargetFile: string;
OutlineMode: Boolean;
CheckOnly: Boolean;
StrictMode: Boolean;
EditPlanTarget: string;
EditPlanSpecified: Boolean;
DiffMode: Boolean;
FixForward: Boolean;
CheckForward: Boolean;
  AddForward: Boolean;
  FixAll: Boolean;
  OutputRawMode: Boolean;
  InsertBeforeTarget: string;
  InsertAfterTarget: string;
  FilterPattern: string;
  ReadFullMode: string;
  ReadFullLine: Integer;
  AddInclude: Boolean;
  AddBlock: Boolean;
  InsertFilePath: string;
  InsertFileBeforeTarget: string;
  InsertFileAfterTarget: string;
  BeforeTarget: string;
  AfterTarget: string;
  InsertLines: TStringArray;
  DryRunMode: Boolean;
  FileText: string;
  K: Integer;
  InsertAfterMode: Boolean;
  ResolvedTarget: string;
  StartLn: Integer;
  EndLn: Integer;
  LazarusProject: string;
DeleteTarget: string;
ReplaceTarget: string;
ReplaceText: string;
InsertLoc: string;
InsertText: string;
OutFile: string;
DoDelete: Boolean;
DoReplace: Boolean;
DoInsert: Boolean;
VerifyMode: Boolean;
JsonMode: Boolean;
SarifMode: Boolean;
NoCacheMode: Boolean;
ClearCacheMode: Boolean;
CacheLoaded: Boolean; FixIndentMode: Boolean; IndentSize: Integer; BeautifyRootIdx: Integer;

ShowByteOffsets: Boolean;
LazarusProjectFiles: TStringArray;
UnitPaths: TStringArray;
UnitsMode: Boolean;
UnitStack: TIntArray;
ParsedUnits: TIntArray;
ReportFilterSet: Boolean;
ReportOpts: TReportSections;
FindPattern: string;
CallersTarget: string;
OrphansMode: Boolean;
ShowRoutineTarget: string;
LinesSliceSpec: string;
SearchPattern: string;
SearchInTarget: string;
ScopeBlockIdx: Integer;
GetBlockMode: Boolean;
GetBlockTarget: string;
GetBlockWithOrigin: Boolean;
GetBlockStandalone: Boolean;
GlobalLinesMode: Boolean;
GlobalLineMode: Boolean;
GlobalLinesSpec: string;
GlobalLineNum: Integer;
EditGLineMode: Boolean;
DeleteGLineMode: Boolean;
EditGLineNum: Integer;
GFile: TIntArray;
GLine: TIntArray;
GlobalStmtsMode: Boolean;
GStmts: TGlobalStmtInfoArray;
GSRootName: string;
GSPathArg: string;
DecodeGSLineMode: Boolean;
LineToGSMode: Boolean;
EdgeLines: array of array of TIntArray;
BlockEditMode: Boolean;
BlockEditTarget: string;
BlockEditMatch: string;
BlockEditReplacement: string;
GlobalEditMode: Boolean;
GlobalDeleteMode: Boolean;
StmtListMode: Boolean;
StmtListTarget: string;
StmtEditMode: Boolean;
StmtEditTarget: string;
StmtEditIndex: Integer;
StmtEditAction: string;
StmtEditText: string;
SuppressLineWarn: Boolean;
FragmentEditMode: Boolean;
FragTarget: string;
FragMatch: string;
FragWith: string;

EditFileIdx: Integer;
GiveBlockNum: Integer;
GiveBlockSpecified: Boolean;
BlockChunkSize: Integer;
BlockSizeSpecified: Boolean;
WidenBlockSteps: Integer;
MaxTreeDepth: Integer;
HideVars: Boolean;
HideFuncs: Boolean;
HideBlocks: Boolean;

{ ============================================================================
Utility, Path, JSON, Usage & Bitmask Helpers
============================================================================ }
procedure CollectGlobalBlockSpans(const Blk: TLogicBlock; var Spans: TStmtSpanArray); forward;

procedure AddIncSearchPath(const RawPath: string); forward;
function GSPathAtLine(FileIdx, Line: Integer): string; forward;
function GSLocationTag(FileIdx, Line: Integer): string; forward;
function ContainsIdentCI(const Text, Ident: string): Boolean; forward;
function IsCommentOnlyLine(FIdx, LineNum: Integer): Boolean; forward;
procedure AddIncSearchPaths(const RawPaths: string); forward;
procedure AddIncSearchPathsRelative(const RawPaths, BaseDir: string); forward;

procedure AddUniqueString(var Arr: TStringArray; const S: string); forward;
procedure AutoLoadLazarusProjectPaths; forward;
function BytePosSuffix(FileIdx, StartLine, EndLine: Integer; ForwardOnly: Boolean): string; forward;
function CmdLineHasWarnUnused: Boolean; forward;
procedure CollectLazarusProjectsInDir(const Dir: string; var OutList: TStringArray); forward;
function ExpandLazarusPathMacros(const S, ProjDir: string): string; forward;
function FlowCallHead(const Callee: string): string; forward;
function FormatFlowCallString(const Callee, ArgsS: string; CloseAsItem: Boolean): string; forward;
function FormatFlowExprString(const S: string): string; forward;
function FormatFlowExprStringAsItem(const S: string): string; forward;
function FormatRoutineFlow(const Kind, Name, RetType: string; const Params: TUsageItemArray; Terminate: Boolean): string; forward;
function FormatUsageFlow(const Item: TUsageItem): string; forward;
function GetFileByteOffset(FileIdx, LineNum, ColNum: Integer): Int64; forward;
function GetLineEndByteOffset(FileIdx, LineNum: Integer): Int64; forward;
function IsDeclaredRoutineName(const Name: string): Boolean; forward;
function IsNumericLiteralText(const T: string): Boolean; forward;
function IsQuotedLiteral(const T: string): Boolean; forward;
function IsSimpleScalarTypeName(const T: string): Boolean; forward;
function IsSysRoutineName(const Name: string): Boolean; forward;
procedure LoadLazarusProjectIncludePaths(const ProjectFile: string); forward;
function QuoteFlowDataLiteral(const S: string): string; forward;
function QuoteFlowDataLiteralTyped(const S, TypeHint: string): string; forward;
function RoutineUsesDeclaredName(const R: TRoutineInfo; const DeclName: string): Boolean; forward;
procedure RunHeuristicChecks; forward;
procedure RunStrictChecks; forward;
function SplitTopLevelCSV(const S: string): TStringArray; forward;
function StripIncQuotes(const S: string): string; forward;
function TryExtractSimpleCall(const S: string; out Callee, ArgsS, Tail: string): Boolean; forward;
function TryResolveIncCandidate(const BaseDir, CleanName: string): string; forward;
function TypeHasSummary(const TD: TTypeDecl): string; forward;
function UsageRefersToName(const UsageName, DeclName: string): Boolean; forward;
function ExtractPropNameType(const D: string; out N, Tn: string): Boolean; forward;
function ExtractMethodName(const Detail, Name: string): string; forward;

function MaxIntVal(A, B: Integer): Integer;
begin
if A > B then
Result := A
else
Result := B;
end;

function MinIntVal(A, B: Integer): Integer;
begin
if A < B then
Result := A
else
Result := B;
end;

function JsonBool(B: Boolean): string;
begin
if B then
Result := 'true'
else
Result := 'false';
end;

function JsonSep(IsLast: Boolean): string;
begin
if IsLast then
Result := ''
else
Result := ',';
end;

function JsonEscape(const S: string): string;
var
I: Integer;
Ch: Char;
begin
Result := '';
for I := 1 to Length(S) do
begin
Ch := S[I];
case Ch of
'"':  Result := Result + '"';
'\':  Result := Result + '\\';
#8:   Result := Result + '\\b';
#9:   Result := Result + '\\t';
#10:  Result := Result + '\\n';
#12:  Result := Result + '\\f';
#13:  Result := Result + '\\r';
else
if Ord(Ch) < 32 then
Result := Result + '\\u' + LowerCase(IntToHex(Ord(Ch), 4))
else
Result := Result + Ch;
end;
end;
end;

function StrContainsCI(const Haystack, Needle: string): Boolean;
begin
if Needle = '' then
Exit(True);
Result := Pos(LowerCase(Needle), LowerCase(Haystack)) > 0;
end;

function GetLineRaw(FileIdx, LineNum: Integer): string;
begin
if (FileIdx >= 0) and (FileIdx < Length(State.Files)) and
(LineNum >= 1) and (LineNum <= Length(State.Files[FileIdx].Lines)) then
Result := State.Files[FileIdx].Lines[LineNum - 1]
else
Result := '';
end;

function GetLineSnippet(FileIdx, LineNum: Integer): string;
begin
Result := Trim(GetLineRaw(FileIdx, LineNum));
end;

function FileDisplay(FileIdx: Integer): string;
begin
if (FileIdx >= 0) and (FileIdx < Length(State.Files)) then
Result := State.Files[FileIdx].DisplayName
else
Result := '';
end;

function SameFilePath(const A, B: string): Boolean;
begin
{$IFDEF WINDOWS}
Result := SameText(A, B);
{$ELSE}
Result := (A = B);
{$ENDIF}
end;

function NormalizePath(const APath: string): string;
var
Clean: string;
begin
Clean := StringReplace(APath, '/', DirectorySeparator, [rfReplaceAll]);
Clean := StringReplace(Clean, '\', DirectorySeparator, [rfReplaceAll]);
Result := ExpandFileName(Clean);
end;

function MakeRelativeDisplay(const NormPath: string): string;
var
Cwd: string;
begin
Cwd := IncludeTrailingPathDelimiter(ExpandFileName(GetCurrentDir));
{$IFDEF WINDOWS}
if SameText(Copy(NormPath, 1, Length(Cwd)), Cwd) then
Exit(Copy(NormPath, Length(Cwd) + 1, MaxInt));
{$ELSE}
if Copy(NormPath, 1, Length(Cwd)) = Cwd then
Exit(Copy(NormPath, Length(Cwd) + 1, MaxInt));
{$ENDIF}
Result := NormPath;
end;

function GetFileStamp(const APath: string; out OutSize, OutMTime: Int64): Boolean;
var
SR: TSearchRec;
begin
Result := False;
OutSize := 0;
OutMTime := 0;
if FindFirst(APath, faAnyFile, SR) = 0 then
begin
try
OutSize := SR.Size;
OutMTime := SR.Time;
Result := True;
finally
SysUtils.FindClose(SR);
end;
end;
end;

procedure SetLocation(var Loc: TLocationInfo; const ADesc: string;
FileIdx, LineNum, ColNum: Integer);
begin
Loc.Valid := True;
Loc.Desc := ADesc;
Loc.FileIdx := FileIdx;
Loc.Line := LineNum;
Loc.Col := ColNum;
Loc.Snippet := GetLineSnippet(FileIdx, LineNum);
end;

procedure AddDiagnostic(FileIdx, LineNum, ColNum, CatBit: Integer;
const Msg: string; const ExtraLabel: string = ''; const ExtraSnippet: string = '');
var
D: TDiagnostic;
begin
D.FileIdx := FileIdx;
D.Line := LineNum;
D.Col := ColNum;
D.CategoryBit := CatBit;
D.Message := Msg;
D.Snippet := GetLineSnippet(FileIdx, LineNum);
D.ExtraLabel := ExtraLabel;
D.ExtraSnippet := ExtraSnippet;
D.LastGoodBlock := LastGoodBlock;
D.LastGoodStmt := LastGoodStmt;
SetLength(State.Diags, Length(State.Diags) + 1);
State.Diags[High(State.Diags)] := D;
end;

function CountUnimplementedDecls: Integer;
var
I: Integer;
begin
Result := 0;
for I := 0 to High(State.Forwards) do
if State.Forwards[I].RequiresImpl and (State.Forwards[I].ImplFileIdx < 0) then
Inc(Result);
end;

function ComputeExitCode: Integer;
var
I: Integer;
begin
Result := 0;
for I := 0 to High(State.Diags) do
begin
if State.Diags[I].CategoryBit <> 0 then
Result := Result or State.Diags[I].CategoryBit
else
Result := Result or EXIT_BIT_SYNTAX;
end;
if CountUnimplementedDecls > 0 then
Result := Result or EXIT_BIT_UNIMPL;
end;

procedure AppendUsage(var List: TUsageItemArray; const AName: string;
FileIdx, LineNum: Integer; const ADetail: string = '');
var
I, N: Integer;
Site: TUsageSite;
begin
Site.FileIdx := FileIdx;
Site.Line := LineNum;

for I := 0 to High(List) do
begin
if SameText(List[I].Name, AName) and SameText(List[I].Detail, ADetail) then
begin
N := Length(List[I].Sites);
if (N = 0) or
(List[I].Sites[N - 1].FileIdx <> FileIdx) or
(List[I].Sites[N - 1].Line <> LineNum) then
begin
SetLength(List[I].Sites, N + 1);
List[I].Sites[N] := Site;
end;
Exit;
end;
end;

N := Length(List);
SetLength(List, N + 1);
List[N].Name := AName;
List[N].Detail := ADetail;
SetLength(List[N].Sites, 1);
List[N].Sites[0] := Site;
end;

procedure SplitSourceLines(const Src: string; out OutLines: TStringArray);
var
SL: TStringList;
I: Integer;
begin
SL := TStringList.Create;
try
SL.Text := Src;
if SL.Count = 0 then
begin
SetLength(OutLines, 1);
OutLines[0] := '';
end
else
begin
SetLength(OutLines, SL.Count);
for I := 0 to SL.Count - 1 do
OutLines[I] := SL[I];
end;
finally
SL.Free;
end;
end;

function ReadEntireFile(const FilePath: string; out Content: string): Boolean;
var
FS: TFileStream;
Sz: Int64;
begin
Result := False;
Content := '';
if not FileExists(FilePath) then
Exit;
try
FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
try
Sz := FS.Size;
SetLength(Content, Sz);
if Sz > 0 then
FS.ReadBuffer(Content[1], Sz);
Result := True;
finally
FS.Free;
end;
except
Result := False;
end;
end;

{ ============================================================================
FreePascal Lexical Scanner (Preserving Exact File-Local Line & Column)
============================================================================ }

function IsAlphaOrUnderscore(Ch: Char): Boolean;
begin
Result := (Ch in ['A'..'Z', 'a'..'z', '_']);
end;

function IsAlnumOrUnderscore(Ch: Char): Boolean;
begin
Result := (Ch in ['A'..'Z', 'a'..'z', '0'..'9', '_']);
end;


function LexPascalSourceEx(const Src: string; var Comments: TCommentInfoArray): TRawTokenArray; forward;


{ Rebuild comment index: sort AllComments by FileIdx then Line, and build
  per-file start/count offsets. Called after all files are loaded. }
{ Append a comment to the singly-linked list (order of lexing = order of files) }
procedure AddComment(ALine, ACol: Integer; const AKind, AText: string);
var N: Integer;
begin
  N := Length(AllComments);
  SetLength(AllComments, N + 1);
  AllComments[N].Next := -1;
  AllComments[N].FileIdx := CurLexFile;
  AllComments[N].Line := ALine;
  AllComments[N].Col := ACol;
  AllComments[N].Kind := AKind;
  AllComments[N].Text := AText;
  if CommentHead < 0 then CommentHead := N else AllComments[CommentTail].Next := N;
  CommentTail := N;
end;

{ Walk the linked list, assign FileIdx from load order, build per-file index.
  No sorting: files are lexed in load order, comments in line order. }
procedure RebuildCommentIndex;
var
  Cur, N, FileIdx: Integer;
begin
  SetLength(CommentIndex, 0);
  Cur := CommentHead;
  while Cur >= 0 do
  begin
    N := AllComments[Cur].Next;
    FileIdx := AllComments[Cur].FileIdx;
    if (Length(CommentIndex) = 0) or
       (CommentIndex[High(CommentIndex)].FileIdx <> FileIdx) then
    begin
      SetLength(CommentIndex, Length(CommentIndex) + 1);
      CommentIndex[High(CommentIndex)].FileIdx := FileIdx;
      CommentIndex[High(CommentIndex)].StartIdx := Cur;
      CommentIndex[High(CommentIndex)].Count := 0;
    end;
    Inc(CommentIndex[High(CommentIndex)].Count);
    Cur := N;
  end;
end;

function LexPascalSource(const Src: string): TRawTokenArray;
var
  Dummy: TCommentInfoArray;
begin
  SetLength(Dummy, 0);
  Result := LexPascalSourceEx(Src, Dummy);
end;

function LexPascalSourceEx(const Src: string; var Comments: TCommentInfoArray): TRawTokenArray;
var
Len, PosIdx, LineNum, LineStart, StartP, SLine, SCol, TokCount, Depth: Integer;
Ch, C1, C2: Char;
Closed: Boolean;
DirBody, LitText, IdentText: string;

procedure EmitTok(AKind: TTokenKind; const AText: string; ALine, ACol: Integer);
begin
if TokCount >= Length(Result) then
SetLength(Result, Length(Result) * 2 + 64);
Result[TokCount].Kind := AKind;
Result[TokCount].Text := AText;
Result[TokCount].Lower := LowerCase(AText);
Result[TokCount].Line := ALine;
Result[TokCount].Col := ACol;
Inc(TokCount);
end;

procedure AdvanceNewline;
begin
if (Src[PosIdx] = #13) and (PosIdx + 1 <= Len) and (Src[PosIdx + 1] = #10) then
Inc(PosIdx, 2)
else
Inc(PosIdx);
Inc(LineNum);
LineStart := PosIdx;
end;

begin
Result := nil;
TokCount := 0;
Len := Length(Src);
PosIdx := 1;
LineNum := 1;
LineStart := 1;

while PosIdx <= Len do
begin
Ch := Src[PosIdx];

{ Whitespace }
if Ch in [' ', #9, #11, #12] then
begin
  Inc(PosIdx);
  Continue;
end;

{ Newline }
if Ch in [#10, #13] then
begin
  AdvanceNewline;
  Continue;
end;

{ Single-line comment // }
if (Ch = '/') and (PosIdx + 1 <= Len) and (Src[PosIdx + 1] = '/') then
begin
  SLine := LineNum;
  SCol := PosIdx - LineStart + 1;
  StartP := PosIdx;
  Inc(PosIdx, 2);
  while (PosIdx <= Len) and not (Src[PosIdx] in [#10, #13]) do
    Inc(PosIdx);
  AddComment(SLine, SCol, '//', Copy(Src, StartP, PosIdx - StartP));
  Continue;
end;

{ Curly-brace comment or compiler directive }
if Ch = '{' then
begin
  SLine := LineNum;
  SCol := PosIdx - LineStart + 1;
  if (PosIdx + 1 <= Len) and (Src[PosIdx + 1] = '$') then
  begin
    { Compiler directive: capture inner text without braces }
    Inc(PosIdx, 2);
    DirBody := '';
    Closed := False;
    while PosIdx <= Len do
    begin
      if Src[PosIdx] = '}' then
      begin
        Inc(PosIdx);
        Closed := True;
        Break;
      end;
      if Src[PosIdx] in [#10, #13] then
      begin
        DirBody := DirBody + ' ';
        AdvanceNewline;
      end
      else
      begin
        DirBody := DirBody + Src[PosIdx];
        Inc(PosIdx);
      end;
    end;
    EmitTok(tkDirective, Trim(DirBody), SLine, SCol);
    if not Closed then
      EmitTok(tkLexError, 'Unterminated compiler directive "{$' + Copy(DirBody, 1, 32) + '"', SLine, SCol);
    Continue;
  end
  else
  begin
    { Standard curly comment (supports nested curly comments in FPC) }
    StartP := PosIdx;
    Inc(PosIdx);
    Depth := 1;
    while (PosIdx <= Len) and (Depth > 0) do
    begin
      if Src[PosIdx] = '{' then
      begin
        Inc(Depth);
        Inc(PosIdx);
      end
      else if Src[PosIdx] = '}' then
      begin
        Dec(Depth);
        Inc(PosIdx);
      end
      else if Src[PosIdx] in [#10, #13] then
        AdvanceNewline
      else
        Inc(PosIdx);
    end;
    AddComment(SLine, SCol, '{}', Copy(Src, StartP, PosIdx - StartP));
    if Depth > 0 then
      EmitTok(tkLexError, 'Unterminated "{ ... }" comment', SLine, SCol);
    Continue;
  end;
end;

{ Parenthesis-star comment or directive (* ... *) }
if (Ch = '(') and (PosIdx + 1 <= Len) and (Src[PosIdx + 1] = '*') then
begin
  SLine := LineNum;
  SCol := PosIdx - LineStart + 1;
  if (PosIdx + 2 <= Len) and (Src[PosIdx + 2] = '$') then
  begin
    Inc(PosIdx, 3);
    DirBody := '';
    Closed := False;
    while PosIdx <= Len do
    begin
      if (Src[PosIdx] = '*') and (PosIdx + 1 <= Len) and (Src[PosIdx + 1] = ')') then
      begin
        Inc(PosIdx, 2);
        Closed := True;
        Break;
      end;
      if Src[PosIdx] in [#10, #13] then
      begin
        DirBody := DirBody + ' ';
        AdvanceNewline;
      end
      else
      begin
        DirBody := DirBody + Src[PosIdx];
        Inc(PosIdx);
      end;
    end;
    EmitTok(tkDirective, Trim(DirBody), SLine, SCol);
    if not Closed then
      EmitTok(tkLexError, 'Unterminated compiler directive "(*$' + Copy(DirBody, 1, 32) + '"', SLine, SCol);
    Continue;
  end
  else
  begin
    Inc(PosIdx, 2);
    Closed := False;
    while PosIdx <= Len do
    begin
      if (Src[PosIdx] = '*') and (PosIdx + 1 <= Len) and (Src[PosIdx + 1] = ')') then
      begin
        Inc(PosIdx, 2);
        Closed := True;
        Break;
      end;
      if Src[PosIdx] in [#10, #13] then
        AdvanceNewline
      else
        Inc(PosIdx);
    end;
    if not Closed then
      EmitTok(tkLexError, 'Unterminated "(* ... *)" comment', SLine, SCol);
    Continue;
  end;
end;

{ Single-quoted Pascal string literal '...' }
if Ch = '''' then
begin
  StartP := PosIdx;
  SLine := LineNum;
  SCol := PosIdx - LineStart + 1;
  Inc(PosIdx);
  Closed := False;
  while PosIdx <= Len do
  begin
    if Src[PosIdx] = '''' then
    begin
      if (PosIdx + 1 <= Len) and (Src[PosIdx + 1] = '''') then
      begin
        Inc(PosIdx, 2);
        Continue;
      end;
      Inc(PosIdx);
      Closed := True;
      Break;
    end;
    if Src[PosIdx] in [#10, #13] then
      Break;
    Inc(PosIdx);
  end;
  LitText := Copy(Src, StartP, MinIntVal(PosIdx - StartP, 80));
  EmitTok(tkString, LitText, SLine, SCol);
  if not Closed then
    EmitTok(tkLexError, 'Unterminated string literal', SLine, SCol);
  Continue;
end;

{ Character code literal #65 or #$41 }
if (Ch = '#') and (PosIdx + 1 <= Len) and
   ((Src[PosIdx + 1] in ['0'..'9']) or (Src[PosIdx + 1] = '$')) then
begin
  StartP := PosIdx;
  SLine := LineNum;
  SCol := PosIdx - LineStart + 1;
  Inc(PosIdx);
  if Src[PosIdx] = '$' then
  begin
    Inc(PosIdx);
    while (PosIdx <= Len) and (Src[PosIdx] in ['0'..'9', 'A'..'F', 'a'..'f']) do
      Inc(PosIdx);
  end
  else
  begin
    while (PosIdx <= Len) and (Src[PosIdx] in ['0'..'9']) do
      Inc(PosIdx);
  end;
  EmitTok(tkString, Copy(Src, StartP, PosIdx - StartP), SLine, SCol);
  Continue;
end;

{ Identifier or &escaped identifier }
if IsAlphaOrUnderscore(Ch) or
   ((Ch = '&') and (PosIdx + 1 <= Len) and IsAlphaOrUnderscore(Src[PosIdx + 1])) then
begin
  StartP := PosIdx;
  SLine := LineNum;
  SCol := PosIdx - LineStart + 1;
  if Ch = '&' then
    Inc(PosIdx);
  while (PosIdx <= Len) and IsAlnumOrUnderscore(Src[PosIdx]) do
    Inc(PosIdx);
  IdentText := Copy(Src, StartP, PosIdx - StartP);
  EmitTok(tkIdent, IdentText, SLine, SCol);
  Continue;
end;

{ Numeric literals: decimal, $hex, %binary, &octal }
if (Ch in ['0'..'9']) or
   ((Ch = '$') and (PosIdx + 1 <= Len) and (Src[PosIdx + 1] in ['0'..'9', 'A'..'F', 'a'..'f'])) or
   ((Ch = '%') and (PosIdx + 1 <= Len) and (Src[PosIdx + 1] in ['0', '1'])) or
   ((Ch = '&') and (PosIdx + 1 <= Len) and (Src[PosIdx + 1] in ['0'..'7'])) then
begin
  StartP := PosIdx;
  SLine := LineNum;
  SCol := PosIdx - LineStart + 1;
  if Ch in ['$', '%', '&'] then
  begin
    Inc(PosIdx);
    while (PosIdx <= Len) and (Src[PosIdx] in ['0'..'9', 'A'..'F', 'a'..'f']) do
      Inc(PosIdx);
  end
  else
  begin
    while (PosIdx <= Len) and (Src[PosIdx] in ['0'..'9']) do
      Inc(PosIdx);
    if (PosIdx + 1 <= Len) and (Src[PosIdx] = '.') and (Src[PosIdx + 1] in ['0'..'9']) then
    begin
      Inc(PosIdx);
      while (PosIdx <= Len) and (Src[PosIdx] in ['0'..'9']) do
        Inc(PosIdx);
    end;
    if (PosIdx <= Len) and (Src[PosIdx] in ['e', 'E']) then
    begin
      Inc(PosIdx);
      if (PosIdx <= Len) and (Src[PosIdx] in ['+', '-']) then
        Inc(PosIdx);
      while (PosIdx <= Len) and (Src[PosIdx] in ['0'..'9']) do
        Inc(PosIdx);
    end;
  end;
  EmitTok(tkNumber, Copy(Src, StartP, PosIdx - StartP), SLine, SCol);
  Continue;
end;

{ Two-character and single-character symbols }
SLine := LineNum;
SCol := PosIdx - LineStart + 1;
if PosIdx + 1 <= Len then
begin
  C1 := Src[PosIdx];
  C2 := Src[PosIdx + 1];
  if ((C1 = ':') and (C2 = '=')) or
     ((C1 = '<') and (C2 = '=')) or
     ((C1 = '>') and (C2 = '=')) or
     ((C1 = '<') and (C2 = '>')) or
     ((C1 = '.') and (C2 = '.')) or
     ((C1 = '*') and (C2 = '*')) or
     ((C1 = '+') and (C2 = '=')) or
     ((C1 = '-') and (C2 = '=')) or
     ((C1 = '*') and (C2 = '=')) or
     ((C1 = '/') and (C2 = '=')) or
     ((C1 = '>') and (C2 = '<')) then
  begin
    EmitTok(tkSymbol, C1 + C2, SLine, SCol);
    Inc(PosIdx, 2);
    Continue;
  end;
end;

EmitTok(tkSymbol, Ch, SLine, SCol);
Inc(PosIdx);


end;

SetLength(Result, TokCount);
end;

{ ============================================================================
File Loading & Include Resolution
============================================================================ }

function FindLoadedFile(const NormPath: string): Integer;
var
I: Integer;
begin
for I := 0 to High(State.Files) do
if SameFilePath(State.Files[I].FilePath, NormPath) then
Exit(I);
Result := -1;
end;

function LoadAndLexFile(const NormPath, DispName: string;
FromFile, FromLine: Integer): Integer;
var
Existing, Idx: Integer;
Src: string;
FI: TFileInfo;
begin
Existing := FindLoadedFile(NormPath);
if Existing >= 0 then
Exit(Existing);

if not ReadEntireFile(NormPath, Src) then
Exit(-1);

FI.FilePath := NormPath;
FI.DisplayName := DispName;
FI.IncludedFromFile := FromFile;
FI.IncludedFromLine := FromLine;
GetFileStamp(NormPath, FI.FileSize, FI.FileMTime);
SplitSourceLines(Src, FI.Lines);
Idx := Length(State.Files);
CurLexFile := Idx;
FI.Tokens := LexPascalSource(Src);
SetLength(State.Files, Idx + 1);

State.Files[Idx] := FI;
Result := Idx;
end;

function ResolveIncludeFile(const RawIncArg: string; FromFileIdx: Integer): string;
var
CleanName, BaseDir, Cand: string;
I: Integer;
begin
Result := '';
CleanName := Trim(RawIncArg);
if (Length(CleanName) >= 2) and (CleanName[1] = '''') and (CleanName[Length(CleanName)] = '''') then
CleanName := Copy(CleanName, 2, Length(CleanName) - 2);
if CleanName = '' then
Exit;

CleanName := StringReplace(CleanName, '/', DirectorySeparator, [rfReplaceAll]);
CleanName := StringReplace(CleanName, '', DirectorySeparator, [rfReplaceAll]);

{ 1. Directory of the including file }
if (FromFileIdx >= 0) and (FromFileIdx < Length(State.Files)) then
begin
BaseDir := ExtractFilePath(State.Files[FromFileIdx].FilePath);
Cand := BaseDir + CleanName;
if FileExists(Cand) then
Exit(NormalizePath(Cand));
if (ExtractFileExt(CleanName) = '') and FileExists(Cand + '.inc') then
Exit(NormalizePath(Cand + '.inc'));
end;

{ 2. Current working directory }
if FileExists(CleanName) then
Exit(NormalizePath(CleanName));
if (ExtractFileExt(CleanName) = '') and FileExists(CleanName + '.inc') then
Exit(NormalizePath(CleanName + '.inc'));

{ 3. Configured -Fi include directories }
for I := 0 to High(IncPaths) do
begin
Cand := IncludeTrailingPathDelimiter(IncPaths[I]) + CleanName;
if FileExists(Cand) then
Exit(NormalizePath(Cand));
if (ExtractFileExt(CleanName) = '') and FileExists(Cand + '.inc') then
Exit(NormalizePath(Cand + '.inc'));
end;
end;

function ResolveUnitFile(const AName: string; FromFileIdx: Integer): string;
var
  Rel: string;
  I: Integer;
  Exts: TStringArray;

  procedure TryDir(const D: string);
  var C: string; LE: Integer;
  begin
    if Result <> '' then Exit;
    C := IncludeTrailingPathDelimiter(D) + Rel;
    if FileExists(C) then
    begin
      Result := NormalizePath(C);
      Exit;
    end;
    for LE := 0 to High(Exts) do
      if FileExists(C + Exts[LE]) then
      begin
        Result := NormalizePath(C + Exts[LE]);
        Exit;
      end;
  end;

begin
  Result := '';
  Rel := StringReplace(Trim(AName), '.', DirectorySeparator, [rfReplaceAll]);
  if Rel = '' then Exit;
  Exts := nil;
  if ExtractFileExt(Rel) = '' then
  begin
    SetLength(Exts, 3);
    Exts[0] := '.pas';
    Exts[1] := '.pp';
    Exts[2] := '.inc';
  end
  else
  begin
    SetLength(Exts, 1);
    Exts[0] := '';
  end;
  if (FromFileIdx >= 0) and (FromFileIdx < Length(State.Files)) then
    TryDir(ExtractFilePath(State.Files[FromFileIdx].FilePath));
  for I := 0 to High(UnitPaths) do
    TryDir(UnitPaths[I]);
  TryDir(ExtractFilePath(NormalizePath(Options.TargetFile)));
  TryDir(GetCurrentDir);
end;

{ ============================================================================
Binary Audit Cache (.fpaudit.cache)
============================================================================ }

function GetCacheFilePath: string;
begin
Result := ExtractFilePath(NormalizePath(Options.TargetFile)) + CACHE_FILENAME;
end;

procedure WriteStr(FS: TFileStream; const S: string);
var
Len: Int32;
begin
Len := Length(S);
FS.WriteBuffer(Len, SizeOf(Len));
if Len > 0 then
FS.WriteBuffer(S[1], Len);
end;

function ReadStr(FS: TFileStream): string;
var
Len: Int32;
begin
Result := '';
FS.ReadBuffer(Len, SizeOf(Len));
if Len > 0 then
begin
SetLength(Result, Len);
FS.ReadBuffer(Result[1], Len);
end;
end;

procedure WriteUsageList(FS: TFileStream; const List: TUsageItemArray);
var
I, J, Cnt, SCnt: Int32;
begin
Cnt := Length(List);
FS.WriteBuffer(Cnt, SizeOf(Cnt));
for I := 0 to Cnt - 1 do
begin
WriteStr(FS, List[I].Name);
WriteStr(FS, List[I].Detail);
SCnt := Length(List[I].Sites);
FS.WriteBuffer(SCnt, SizeOf(SCnt));
for J := 0 to SCnt - 1 do
begin
FS.WriteBuffer(List[I].Sites[J].FileIdx, SizeOf(Integer));
FS.WriteBuffer(List[I].Sites[J].Line, SizeOf(Integer));
end;
end;
end;

procedure ReadUsageList(FS: TFileStream; out List: TUsageItemArray);
var
I, J, Cnt, SCnt: Int32;
begin
List := nil;
FS.ReadBuffer(Cnt, SizeOf(Cnt));
SetLength(List, Cnt);
for I := 0 to Cnt - 1 do
begin
List[I].Name := ReadStr(FS);
List[I].Detail := ReadStr(FS);
FS.ReadBuffer(SCnt, SizeOf(SCnt));
SetLength(List[I].Sites, SCnt);
for J := 0 to SCnt - 1 do
begin
FS.ReadBuffer(List[I].Sites[J].FileIdx, SizeOf(Integer));
FS.ReadBuffer(List[I].Sites[J].Line, SizeOf(Integer));
end;
end;
end;

procedure WriteMemberItem(FS: TFileStream; const M: TMemberItem);
begin
WriteStr(FS, M.Name);
WriteStr(FS, M.Detail);
WriteStr(FS, M.ValueExpr);
FS.WriteBuffer(M.IsConst, SizeOf(Boolean));
FS.WriteBuffer(M.FileIdx, SizeOf(Integer));
FS.WriteBuffer(M.Line, SizeOf(Integer));
end;

procedure ReadMemberItem(FS: TFileStream; out M: TMemberItem);
begin
M.Name := ReadStr(FS);
M.Detail := ReadStr(FS);
M.ValueExpr := ReadStr(FS);
FS.ReadBuffer(M.IsConst, SizeOf(Boolean));
FS.ReadBuffer(M.FileIdx, SizeOf(Integer));
FS.ReadBuffer(M.Line, SizeOf(Integer));
end;

procedure SaveAuditCache;
var
FS: TFileStream;
I, J, Cnt, SubCnt: Int32;
KindOrd: Byte;
begin
if Options.NoCacheMode or (Length(State.Files) = 0) then
Exit;
try
FS := TFileStream.Create(GetCacheFilePath, fmCreate);
try
WriteStr(FS, CACHE_MAGIC);
WriteStr(FS, NormalizePath(Options.TargetFile));

  Cnt := Length(IncPaths);
  FS.WriteBuffer(Cnt, SizeOf(Cnt));
  for I := 0 to Cnt - 1 do
    WriteStr(FS, IncPaths[I]);

  Cnt := Length(State.Files);
  FS.WriteBuffer(Cnt, SizeOf(Cnt));
  for I := 0 to Cnt - 1 do
  begin
    WriteStr(FS, State.Files[I].FilePath);
    WriteStr(FS, State.Files[I].DisplayName);
    FS.WriteBuffer(State.Files[I].IncludedFromFile, SizeOf(Integer));
    FS.WriteBuffer(State.Files[I].IncludedFromLine, SizeOf(Integer));
    FS.WriteBuffer(State.Files[I].FileSize, SizeOf(Int64));
    FS.WriteBuffer(State.Files[I].FileMTime, SizeOf(Int64));
  end;

  Cnt := Length(State.TreeEdges);
  FS.WriteBuffer(Cnt, SizeOf(Cnt));
  for I := 0 to Cnt - 1 do
  begin
    FS.WriteBuffer(State.TreeEdges[I].ParentFileIdx, SizeOf(Integer));
    FS.WriteBuffer(State.TreeEdges[I].ParentLine, SizeOf(Integer));
    WriteStr(FS, State.TreeEdges[I].EdgeKind);
    WriteStr(FS, State.TreeEdges[I].TargetDisplay);
    FS.WriteBuffer(State.TreeEdges[I].TargetFileIdx, SizeOf(Integer));
    WriteStr(FS, State.TreeEdges[I].InsideRoutine);
    FS.WriteBuffer(State.TreeEdges[I].AlreadyIncluded, SizeOf(Boolean));
  end;

  Cnt := Length(State.Diags);
  FS.WriteBuffer(Cnt, SizeOf(Cnt));
  for I := 0 to Cnt - 1 do
  begin
    FS.WriteBuffer(State.Diags[I].FileIdx, SizeOf(Integer));
    FS.WriteBuffer(State.Diags[I].Line, SizeOf(Integer));
    FS.WriteBuffer(State.Diags[I].Col, SizeOf(Integer));
    FS.WriteBuffer(State.Diags[I].CategoryBit, SizeOf(Integer));
    WriteStr(FS, State.Diags[I].Message);
    WriteStr(FS, State.Diags[I].Snippet);
    WriteStr(FS, State.Diags[I].ExtraLabel);
    WriteStr(FS, State.Diags[I].ExtraSnippet);
    FS.WriteBuffer(State.Diags[I].LastGoodBlock.Valid, SizeOf(Boolean));
    WriteStr(FS, State.Diags[I].LastGoodBlock.Desc);
    FS.WriteBuffer(State.Diags[I].LastGoodBlock.FileIdx, SizeOf(Integer));
    FS.WriteBuffer(State.Diags[I].LastGoodBlock.Line, SizeOf(Integer));
    FS.WriteBuffer(State.Diags[I].LastGoodBlock.Col, SizeOf(Integer));
    WriteStr(FS, State.Diags[I].LastGoodBlock.Snippet);
    FS.WriteBuffer(State.Diags[I].LastGoodStmt.Valid, SizeOf(Boolean));
    WriteStr(FS, State.Diags[I].LastGoodStmt.Desc);
    FS.WriteBuffer(State.Diags[I].LastGoodStmt.FileIdx, SizeOf(Integer));
    FS.WriteBuffer(State.Diags[I].LastGoodStmt.Line, SizeOf(Integer));
    FS.WriteBuffer(State.Diags[I].LastGoodStmt.Col, SizeOf(Integer));
    WriteStr(FS, State.Diags[I].LastGoodStmt.Snippet);
  end;

  Cnt := Length(State.Types);
  FS.WriteBuffer(Cnt, SizeOf(Cnt));
  for I := 0 to Cnt - 1 do
  begin
    WriteStr(FS, State.Types[I].Name);
    WriteStr(FS, State.Types[I].Kind);
    FS.WriteBuffer(State.Types[I].FileIdx, SizeOf(Integer));
    FS.WriteBuffer(State.Types[I].StartLine, SizeOf(Integer));
    FS.WriteBuffer(State.Types[I].EndLine, SizeOf(Integer));
    FS.WriteBuffer(State.Types[I].IsForward, SizeOf(Boolean));
    SubCnt := Length(State.Types[I].Fields);
    FS.WriteBuffer(SubCnt, SizeOf(SubCnt));
    for J := 0 to SubCnt - 1 do
      WriteMemberItem(FS, State.Types[I].Fields[J]);
    SubCnt := Length(State.Types[I].Methods);
    FS.WriteBuffer(SubCnt, SizeOf(SubCnt));
    for J := 0 to SubCnt - 1 do
      WriteMemberItem(FS, State.Types[I].Methods[J]);
  end;

  Cnt := Length(State.Globals);
  FS.WriteBuffer(Cnt, SizeOf(Cnt));
  for I := 0 to Cnt - 1 do
    WriteMemberItem(FS, State.Globals[I]);

  Cnt := Length(State.Forwards);
  FS.WriteBuffer(Cnt, SizeOf(Cnt));
  for I := 0 to Cnt - 1 do
  begin
    WriteStr(FS, State.Forwards[I].Name);
    WriteStr(FS, State.Forwards[I].Kind);
    WriteStr(FS, State.Forwards[I].Signature);
    FS.WriteBuffer(State.Forwards[I].FileIdx, SizeOf(Integer));
    FS.WriteBuffer(State.Forwards[I].Line, SizeOf(Integer));
    FS.WriteBuffer(State.Forwards[I].RequiresImpl, SizeOf(Boolean));
    FS.WriteBuffer(State.Forwards[I].ImplFileIdx, SizeOf(Integer));
    FS.WriteBuffer(State.Forwards[I].ImplLine, SizeOf(Integer));
  end;

  Cnt := Length(State.Routines);
  FS.WriteBuffer(Cnt, SizeOf(Cnt));
  for I := 0 to Cnt - 1 do
  begin
    WriteStr(FS, State.Routines[I].Name);
    WriteStr(FS, State.Routines[I].Kind);
    WriteStr(FS, State.Routines[I].ReturnType);
    FS.WriteBuffer(State.Routines[I].FileIdx, SizeOf(Integer));
    FS.WriteBuffer(State.Routines[I].StartLine, SizeOf(Integer));
    FS.WriteBuffer(State.Routines[I].EndFileIdx, SizeOf(Integer));
    FS.WriteBuffer(State.Routines[I].EndLine, SizeOf(Integer));
    FS.WriteBuffer(State.Routines[I].RootBlockIdx, SizeOf(Integer));
    WriteUsageList(FS, State.Routines[I].Includes);
    WriteUsageList(FS, State.Routines[I].Params);
    WriteUsageList(FS, State.Routines[I].Locals);
    WriteUsageList(FS, State.Routines[I].Assigns);
    WriteUsageList(FS, State.Routines[I].Vars);
    WriteUsageList(FS, State.Routines[I].Calls);
  end;

  Cnt := Length(State.LogicBlocks);
  FS.WriteBuffer(Cnt, SizeOf(Cnt));
  for I := 0 to Cnt - 1 do
  begin
    FS.WriteBuffer(State.LogicBlocks[I].Id, SizeOf(Integer));
    KindOrd := Ord(State.LogicBlocks[I].Kind);
    FS.WriteBuffer(KindOrd, SizeOf(Byte));
    WriteStr(FS, State.LogicBlocks[I].LabelText);
    FS.WriteBuffer(State.LogicBlocks[I].OwnerRoutineIdx, SizeOf(Integer));
    FS.WriteBuffer(State.LogicBlocks[I].ParentIdx, SizeOf(Integer));
    FS.WriteBuffer(State.LogicBlocks[I].Depth, SizeOf(Integer));
    FS.WriteBuffer(State.LogicBlocks[I].FileIdx, SizeOf(Integer));
    FS.WriteBuffer(State.LogicBlocks[I].StartLine, SizeOf(Integer));
    FS.WriteBuffer(State.LogicBlocks[I].EndFileIdx, SizeOf(Integer));
    FS.WriteBuffer(State.LogicBlocks[I].EndLine, SizeOf(Integer));
    SubCnt := Length(State.LogicBlocks[I].Children);
    FS.WriteBuffer(SubCnt, SizeOf(SubCnt));
    for J := 0 to SubCnt - 1 do
      FS.WriteBuffer(State.LogicBlocks[I].Children[J], SizeOf(Integer));
  end;
finally
  FS.Free;
end;


except
{ Ignore non-fatal cache write failures }
end;
end;

function TryLoadAuditCache: Boolean;
var
CachePath, Magic, CachedRoot, Src: string;
FS: TFileStream;
I, J, Cnt, SubCnt: Int32;
CurSz, CurMt: Int64;
KindOrd: Byte;
begin
Result := False;
if Options.NoCacheMode then
Exit;
CachePath := GetCacheFilePath;
if not FileExists(CachePath) then
Exit;

try
FS := TFileStream.Create(CachePath, fmOpenRead or fmShareDenyNone);
try
Magic := ReadStr(FS);
if Magic <> CACHE_MAGIC then
Exit;
CachedRoot := ReadStr(FS);
if not SameFilePath(CachedRoot, NormalizePath(Options.TargetFile)) then
Exit;

  FS.ReadBuffer(Cnt, SizeOf(Cnt));
  if Cnt <> Length(IncPaths) then
    Exit;
  for I := 0 to Cnt - 1 do
    if not SameFilePath(ReadStr(FS), IncPaths[I]) then
      Exit;

  FS.ReadBuffer(Cnt, SizeOf(Cnt));
  if Cnt <= 0 then
    Exit;
  SetLength(State.Files, Cnt);
  for I := 0 to Cnt - 1 do
  begin
    State.Files[I].FilePath := ReadStr(FS);
    State.Files[I].DisplayName := ReadStr(FS);
    FS.ReadBuffer(State.Files[I].IncludedFromFile, SizeOf(Integer));
    FS.ReadBuffer(State.Files[I].IncludedFromLine, SizeOf(Integer));
    FS.ReadBuffer(State.Files[I].FileSize, SizeOf(Int64));
    FS.ReadBuffer(State.Files[I].FileMTime, SizeOf(Int64));

    if not GetFileStamp(State.Files[I].FilePath, CurSz, CurMt) then
    begin
      SetLength(State.Files, 0);
      Exit;
    end;
    if (CurSz <> State.Files[I].FileSize) or (CurMt <> State.Files[I].FileMTime) then
    begin
      SetLength(State.Files, 0);
      Exit;
    end;
  end;

  { Reload source lines and tokens for fast slicing & token search }
  for I := 0 to High(State.Files) do
  begin
    if not ReadEntireFile(State.Files[I].FilePath, Src) then
      Exit;
    SplitSourceLines(Src, State.Files[I].Lines);
    State.Files[I].Tokens := LexPascalSource(Src);
  end;

  FS.ReadBuffer(Cnt, SizeOf(Cnt));
  SetLength(State.TreeEdges, Cnt);
  for I := 0 to Cnt - 1 do
  begin
    FS.ReadBuffer(State.TreeEdges[I].ParentFileIdx, SizeOf(Integer));
    FS.ReadBuffer(State.TreeEdges[I].ParentLine, SizeOf(Integer));
    State.TreeEdges[I].EdgeKind := ReadStr(FS);
    State.TreeEdges[I].TargetDisplay := ReadStr(FS);
    FS.ReadBuffer(State.TreeEdges[I].TargetFileIdx, SizeOf(Integer));
    State.TreeEdges[I].InsideRoutine := ReadStr(FS);
    FS.ReadBuffer(State.TreeEdges[I].AlreadyIncluded, SizeOf(Boolean));
  end;

  FS.ReadBuffer(Cnt, SizeOf(Cnt));
  SetLength(State.Diags, Cnt);
  for I := 0 to Cnt - 1 do
  begin
    FS.ReadBuffer(State.Diags[I].FileIdx, SizeOf(Integer));
    FS.ReadBuffer(State.Diags[I].Line, SizeOf(Integer));
    FS.ReadBuffer(State.Diags[I].Col, SizeOf(Integer));
    FS.ReadBuffer(State.Diags[I].CategoryBit, SizeOf(Integer));
    State.Diags[I].Message := ReadStr(FS);
    State.Diags[I].Snippet := ReadStr(FS);
    State.Diags[I].ExtraLabel := ReadStr(FS);
    State.Diags[I].ExtraSnippet := ReadStr(FS);
    FS.ReadBuffer(State.Diags[I].LastGoodBlock.Valid, SizeOf(Boolean));
    State.Diags[I].LastGoodBlock.Desc := ReadStr(FS);
    FS.ReadBuffer(State.Diags[I].LastGoodBlock.FileIdx, SizeOf(Integer));
    FS.ReadBuffer(State.Diags[I].LastGoodBlock.Line, SizeOf(Integer));
    FS.ReadBuffer(State.Diags[I].LastGoodBlock.Col, SizeOf(Integer));
    State.Diags[I].LastGoodBlock.Snippet := ReadStr(FS);
    FS.ReadBuffer(State.Diags[I].LastGoodStmt.Valid, SizeOf(Boolean));
    State.Diags[I].LastGoodStmt.Desc := ReadStr(FS);
    FS.ReadBuffer(State.Diags[I].LastGoodStmt.FileIdx, SizeOf(Integer));
    FS.ReadBuffer(State.Diags[I].LastGoodStmt.Line, SizeOf(Integer));
    FS.ReadBuffer(State.Diags[I].LastGoodStmt.Col, SizeOf(Integer));
    State.Diags[I].LastGoodStmt.Snippet := ReadStr(FS);
  end;

  FS.ReadBuffer(Cnt, SizeOf(Cnt));
  SetLength(State.Types, Cnt);
  for I := 0 to Cnt - 1 do
  begin
    State.Types[I].Name := ReadStr(FS);
    State.Types[I].Kind := ReadStr(FS);
    FS.ReadBuffer(State.Types[I].FileIdx, SizeOf(Integer));
    FS.ReadBuffer(State.Types[I].StartLine, SizeOf(Integer));
    FS.ReadBuffer(State.Types[I].EndLine, SizeOf(Integer));
    FS.ReadBuffer(State.Types[I].IsForward, SizeOf(Boolean));
    FS.ReadBuffer(SubCnt, SizeOf(SubCnt));
    SetLength(State.Types[I].Fields, SubCnt);
    for J := 0 to SubCnt - 1 do
      ReadMemberItem(FS, State.Types[I].Fields[J]);
    FS.ReadBuffer(SubCnt, SizeOf(SubCnt));
    SetLength(State.Types[I].Methods, SubCnt);
    for J := 0 to SubCnt - 1 do
      ReadMemberItem(FS, State.Types[I].Methods[J]);
  end;

  FS.ReadBuffer(Cnt, SizeOf(Cnt));
  SetLength(State.Globals, Cnt);
  for I := 0 to Cnt - 1 do
    ReadMemberItem(FS, State.Globals[I]);

  FS.ReadBuffer(Cnt, SizeOf(Cnt));
  SetLength(State.Forwards, Cnt);
  for I := 0 to Cnt - 1 do
  begin
    State.Forwards[I].Name := ReadStr(FS);
    State.Forwards[I].Kind := ReadStr(FS);
    State.Forwards[I].Signature := ReadStr(FS);
    FS.ReadBuffer(State.Forwards[I].FileIdx, SizeOf(Integer));
    FS.ReadBuffer(State.Forwards[I].Line, SizeOf(Integer));
    FS.ReadBuffer(State.Forwards[I].RequiresImpl, SizeOf(Boolean));
    FS.ReadBuffer(State.Forwards[I].ImplFileIdx, SizeOf(Integer));
    FS.ReadBuffer(State.Forwards[I].ImplLine, SizeOf(Integer));
  end;

  FS.ReadBuffer(Cnt, SizeOf(Cnt));
  SetLength(State.Routines, Cnt);
  for I := 0 to Cnt - 1 do
  begin
    State.Routines[I].Name := ReadStr(FS);
    State.Routines[I].Kind := ReadStr(FS);
    State.Routines[I].ReturnType := ReadStr(FS);
    FS.ReadBuffer(State.Routines[I].FileIdx, SizeOf(Integer));
    FS.ReadBuffer(State.Routines[I].StartLine, SizeOf(Integer));
    FS.ReadBuffer(State.Routines[I].EndFileIdx, SizeOf(Integer));
    FS.ReadBuffer(State.Routines[I].EndLine, SizeOf(Integer));
    FS.ReadBuffer(State.Routines[I].RootBlockIdx, SizeOf(Integer));
    ReadUsageList(FS, State.Routines[I].Includes);
    ReadUsageList(FS, State.Routines[I].Params);
    ReadUsageList(FS, State.Routines[I].Locals);
    ReadUsageList(FS, State.Routines[I].Assigns);
    ReadUsageList(FS, State.Routines[I].Vars);
    ReadUsageList(FS, State.Routines[I].Calls);
  end;

  FS.ReadBuffer(Cnt, SizeOf(Cnt));
  SetLength(State.LogicBlocks, Cnt);
  for I := 0 to Cnt - 1 do
  begin
    FS.ReadBuffer(State.LogicBlocks[I].Id, SizeOf(Integer));
    FS.ReadBuffer(KindOrd, SizeOf(Byte));
    State.LogicBlocks[I].Kind := TLogicBlockKind(KindOrd);
    State.LogicBlocks[I].LabelText := ReadStr(FS);
    FS.ReadBuffer(State.LogicBlocks[I].OwnerRoutineIdx, SizeOf(Integer));
    FS.ReadBuffer(State.LogicBlocks[I].ParentIdx, SizeOf(Integer));
    FS.ReadBuffer(State.LogicBlocks[I].Depth, SizeOf(Integer));
    FS.ReadBuffer(State.LogicBlocks[I].FileIdx, SizeOf(Integer));
    FS.ReadBuffer(State.LogicBlocks[I].StartLine, SizeOf(Integer));
    FS.ReadBuffer(State.LogicBlocks[I].EndFileIdx, SizeOf(Integer));
    FS.ReadBuffer(State.LogicBlocks[I].EndLine, SizeOf(Integer));
    FS.ReadBuffer(SubCnt, SizeOf(SubCnt));
    SetLength(State.LogicBlocks[I].Children, SubCnt);
    for J := 0 to SubCnt - 1 do
      FS.ReadBuffer(State.LogicBlocks[I].Children[J], SizeOf(Integer));
  end;

  Result := True;
finally
  FS.Free;
end;


except
Result := False;
SetLength(State.Files, 0);
end;
end;

{ ============================================================================
Pascal Keyword, Type Resolution & Logic Block Helpers
============================================================================ }

function IsPascalKeyword(const Low: string): Boolean;
begin
Result :=
(Low = 'and') or (Low = 'array') or (Low = 'as') or (Low = 'asm') or
(Low = 'begin') or (Low = 'case') or (Low = 'class') or (Low = 'const') or
(Low = 'constructor') or (Low = 'destructor') or (Low = 'div') or (Low = 'do') or
(Low = 'downto') or (Low = 'else') or (Low = 'end') or (Low = 'except') or
(Low = 'exports') or (Low = 'file') or (Low = 'finalization') or (Low = 'finally') or
(Low = 'for') or (Low = 'function') or (Low = 'goto') or (Low = 'if') or
(Low = 'implementation') or (Low = 'in') or (Low = 'inherited') or
(Low = 'initialization') or (Low = 'inline') or (Low = 'interface') or
(Low = 'is') or (Low = 'label') or (Low = 'library') or (Low = 'mod') or
(Low = 'nil') or (Low = 'not') or (Low = 'object') or (Low = 'of') or
(Low = 'operator') or (Low = 'or') or (Low = 'packed') or (Low = 'procedure') or
(Low = 'program') or (Low = 'property') or (Low = 'raise') or (Low = 'record') or
(Low = 'repeat') or (Low = 'resourcestring') or (Low = 'set') or (Low = 'shl') or
(Low = 'shr') or (Low = 'string') or (Low = 'then') or (Low = 'threadvar') or
(Low = 'to') or (Low = 'try') or (Low = 'type') or (Low = 'unit') or
(Low = 'until') or (Low = 'uses') or (Low = 'var') or (Low = 'while') or
(Low = 'with') or (Low = 'xor') or (Low = 'true') or (Low = 'false') or
(Low = 'stdcall') or (Low = 'cdecl') or (Low = 'safecall') or (Low = 'varargs') or
(Low = 'register') or (Low = 'pascal') or (Low = 'assembler') or (Low = 'nostackframe') or
(Low = 'deprecated') or (Low = 'platform') or (Low = 'experimental') or (Low = 'external') or
(Low = 'forward') or (Low = 'overload') or (Low = 'override') or (Low = 'virtual') or
(Low = 'abstract') or (Low = 'reintroduce') or (Low = 'static') or (Low = 'out') or
(Low = 'constref') or (Low = 'generic') or (Low = 'specialize') or (Low = 'absolute');
end;

function IsRoutineStarter(const Low: string): Boolean;
begin
Result := (Low = 'procedure') or (Low = 'function') or
(Low = 'constructor') or (Low = 'destructor') or
(Low = 'operator');
end;

function IsAssignSymbol(const S: string): Boolean;
begin
Result := (S = ':=') or (S = '+=') or (S = '-=') or (S = '*=') or (S = '/=');
end;

function FindMatchingClose(const Toks: TRawTokenArray; OpenIdx: Integer;
const OpenS, CloseS: string): Integer;
var
Depth, Count: Integer;
begin
Count := Length(Toks);
Depth := 1;
Result := OpenIdx + 1;
while (Result < Count) and (Depth > 0) do
begin
if Toks[Result].Lower = OpenS then
Inc(Depth)
else if Toks[Result].Lower = CloseS then
Dec(Depth);
if Depth > 0 then
Inc(Result);
end;
end;

function LookupMemberInType(const TypeName, MemberName: string): string;
var
Clean: string;
Hop, I, M: Integer;
Followed: Boolean;
begin
Result := '';
Clean := Trim(TypeName);
if Clean = '' then
Exit;

for Hop := 1 to 8 do
begin
Followed := False;
for I := 0 to High(State.Types) do
begin
if SameText(State.Types[I].Name, Clean) then
begin
for M := 0 to High(State.Types[I].Fields) do
if SameText(State.Types[I].Fields[M].Name, MemberName) then
Exit(State.Types[I].Fields[M].Detail);
for M := 0 to High(State.Types[I].Methods) do
if SameText(State.Types[I].Methods[M].Name, MemberName) then
Exit(State.Types[I].Methods[M].Detail);

    if (Length(State.Types[I].Fields) = 0) and
       (Pos(' ', State.Types[I].Kind) = 0) and
       (not SameText(State.Types[I].Kind, 'record')) and
       (not SameText(State.Types[I].Kind, 'class')) and
       (not SameText(State.Types[I].Kind, 'object')) and
       (not SameText(State.Types[I].Kind, 'interface')) and
       (not SameText(State.Types[I].Kind, 'enum')) then
    begin
      Clean := State.Types[I].Kind;
      Followed := True;
      Break;
    end;
  end;
end;
if not Followed then
  Break;


end;
end;

function ResolveVarType(ActiveRtnIdx: Integer; const Chain: string): string;
var
DotPos, P, I: Integer;
Base, Member, CurType: string;
begin
Result := '';
DotPos := Pos('.', Chain);
if DotPos > 0 then
Base := Copy(Chain, 1, DotPos - 1)
else
Base := Chain;
if Base = '' then
Exit;

CurType := '';
if (ActiveRtnIdx >= 0) and (ActiveRtnIdx < Length(State.Routines)) then
begin
for I := 0 to High(State.Routines[ActiveRtnIdx].Locals) do
if SameText(State.Routines[ActiveRtnIdx].Locals[I].Name, Base) then
begin
CurType := State.Routines[ActiveRtnIdx].Locals[I].Detail;
Break;
end;
if CurType = '' then
for I := 0 to High(State.Routines[ActiveRtnIdx].Params) do
if SameText(State.Routines[ActiveRtnIdx].Params[I].Name, Base) then
begin
CurType := State.Routines[ActiveRtnIdx].Params[I].Detail;
Break;
end;
if (CurType = '') and SameText(Base, 'Result') then
CurType := State.Routines[ActiveRtnIdx].ReturnType;
end;

if CurType = '' then
for I := 0 to High(State.Globals) do
if SameText(State.Globals[I].Name, Base) then
begin
CurType := State.Globals[I].Detail;
Break;
end;

if DotPos > 0 then
begin
P := DotPos + 1;
while (CurType <> '') and (P <= Length(Chain)) do
begin
Member := '';
while (P <= Length(Chain)) and (Chain[P] <> '.') do
begin
Member := Member + Chain[P];
Inc(P);
end;
if (P <= Length(Chain)) and (Chain[P] = '.') then
Inc(P);
if Member = '' then
Break;
CurType := LookupMemberInType(CurType, Member);
end;
end;
Result := CurType;
end;

function FormatExprSlice(const Toks: TRawTokenArray; StartIdx, EndIdx: Integer;
ActiveRtnIdx: Integer; AnnotateTypes: Boolean): string;
var
I, Q: Integer;
Prev, Cur, Chain, VType: string;
NeedSpace: Boolean;
PC, CC: Char;
begin
Result := '';
Prev := '';
I := StartIdx;
while I <= EndIdx do
begin
if Toks[I].Kind in [tkDirective, tkLexError] then
begin
Inc(I);
Continue;
end;

if AnnotateTypes and (Toks[I].Kind = tkIdent) and (not IsPascalKeyword(Toks[I].Lower)) then
begin
  Chain := Toks[I].Text;
  Q := I + 1;
  while (Q + 1 <= EndIdx) and (Toks[Q].Text = '.') and (Toks[Q + 1].Kind = tkIdent) do
  begin
    Chain := Chain + '.' + Toks[Q + 1].Text;
    Inc(Q, 2);
  end;
  VType := ResolveVarType(ActiveRtnIdx, Chain);
  if (Result <> '') and (Prev <> '') then
  begin
    PC := Prev[Length(Prev)];
    if IsAlnumOrUnderscore(PC) or (Prev = ',') then
      Result := Result + ' ';
  end;
  Result := Result + Chain;
  if VType <> '' then
    Result := Result + ':' + VType;
  Prev := Toks[Q - 1].Text;
  I := Q;
  Continue;
end;

Cur := Toks[I].Text;
NeedSpace := False;
if (Result <> '') and (Prev <> '') and (Cur <> '') then
begin
  PC := Prev[Length(Prev)];
  CC := Cur[1];
  if (Prev = ',') or (Prev = ':') then
    NeedSpace := True
  else if IsAlnumOrUnderscore(PC) and IsAlnumOrUnderscore(CC) then
    NeedSpace := True
  else if (Cur = ':=') or (Prev = ':=') or (Cur = '=') or (Prev = '=') or
          (Cur = '<>') or (Prev = '<>') or (Cur = '<=') or (Prev = '<=') or
          (Cur = '>=') or (Prev = '>=') or (Cur = '+') or (Prev = '+') or
          (Cur = '-') or (Prev = '-') then
    NeedSpace := True;
end;
if NeedSpace then
  Result := Result + ' ';
Result := Result + Cur;
Prev := Cur;
Inc(I);


end;
end;

function AddLogicBlock(AKind: TLogicBlockKind; const ALabel: string;
OwnerRtnIdx, ParentBlockIdx, FileIdx, StartLn, EndFileIdx, EndLn: Integer): Integer;
var
Idx, CCount: Integer;
begin
Idx := Length(State.LogicBlocks);
SetLength(State.LogicBlocks, Idx + 1);
State.LogicBlocks[Idx].Id := Idx + 1;
State.LogicBlocks[Idx].Kind := AKind;
State.LogicBlocks[Idx].LabelText := ALabel;
State.LogicBlocks[Idx].OwnerRoutineIdx := OwnerRtnIdx;
State.LogicBlocks[Idx].ParentIdx := ParentBlockIdx;
if (ParentBlockIdx >= 0) and (ParentBlockIdx < Idx) then
State.LogicBlocks[Idx].Depth := State.LogicBlocks[ParentBlockIdx].Depth + 1
else
State.LogicBlocks[Idx].Depth := 0;
State.LogicBlocks[Idx].FileIdx := FileIdx;
State.LogicBlocks[Idx].StartLine := StartLn;
State.LogicBlocks[Idx].EndFileIdx := EndFileIdx;
State.LogicBlocks[Idx].EndLine := EndLn;
State.LogicBlocks[Idx].Children := nil;

if (ParentBlockIdx >= 0) and (ParentBlockIdx < Idx) then
begin
CCount := Length(State.LogicBlocks[ParentBlockIdx].Children);
SetLength(State.LogicBlocks[ParentBlockIdx].Children, CCount + 1);
State.LogicBlocks[ParentBlockIdx].Children[CCount] := Idx;
end;

Result := Idx;
end;

procedure CloseLogicBlock(BlockIdx, EndFileIdx, EndLn: Integer);
begin
if (BlockIdx >= 0) and (BlockIdx < Length(State.LogicBlocks)) then
begin
State.LogicBlocks[BlockIdx].EndFileIdx := EndFileIdx;
State.LogicBlocks[BlockIdx].EndLine := EndLn;
end;
end;

{ Prototype: emit GAP_ containers for any line in FileIdx not covered by an
  existing logic block. This guarantees a full, ordered line coverage so every
  line in a parsed file is reachable via a block handle. }
procedure EmitCoveringGaps(FileIdx: Integer);
var
Covered: TBoolArray;
I, L, LastLine, GStart, BlkEnd: Integer;
begin
LastLine := Length(State.Files[FileIdx].Lines);
if LastLine <= 0 then Exit;
SetLength(Covered, LastLine + 1);
for L := 1 to LastLine do Covered[L] := False;

for I := 0 to High(State.LogicBlocks) do
  if State.LogicBlocks[I].FileIdx = FileIdx then
  begin
    L := State.LogicBlocks[I].StartLine;
    if L < 1 then L := 1;
    if State.LogicBlocks[I].EndFileIdx = FileIdx then
      BlkEnd := State.LogicBlocks[I].EndLine
    else
      BlkEnd := LastLine;
    if BlkEnd > LastLine then BlkEnd := LastLine;
    while L <= BlkEnd do
    begin
      Covered[L] := True;
      Inc(L);
    end;
  end;

GStart := 0;
for L := 1 to LastLine do
begin
  if not Covered[L] then
  begin
    if GStart = 0 then GStart := L;
  end
  else if GStart > 0 then
  begin
    AddLogicBlock(bkGap, 'uncovered source span', -1, -1, FileIdx, GStart, FileIdx, L - 1);
    GStart := 0;
  end;
end;
if GStart > 0 then
  AddLogicBlock(bkGap, 'uncovered source span', -1, -1, FileIdx, GStart, FileIdx, LastLine);
end;

{ Prototype: rebuild parent/child links from source-span containment so section
  containers own their declarations, and root containers form a non-overlapping
  ordered covering of each file. }
procedure RebuildContainerHierarchy;
var
  B, C, Best, BestSpan, Span, D, Pass: Integer;
  NewParent: TIntArray;
  Changed: Boolean;
begin
  SetLength(NewParent, Length(State.LogicBlocks));
  for B := 0 to High(State.LogicBlocks) do
  begin
    NewParent[B] := -1;
    Best := -1;
    BestSpan := MaxInt;
    for C := 0 to High(State.LogicBlocks) do
    begin
      if C = B then Continue;
      if State.LogicBlocks[C].FileIdx <> State.LogicBlocks[B].FileIdx then Continue;
      if State.LogicBlocks[C].EndFileIdx <> State.LogicBlocks[B].EndFileIdx then Continue;
      if (State.LogicBlocks[C].StartLine <= State.LogicBlocks[B].StartLine) and
         (State.LogicBlocks[C].EndLine >= State.LogicBlocks[B].EndLine) then
      begin
        if (State.LogicBlocks[C].StartLine < State.LogicBlocks[B].StartLine) or
           (State.LogicBlocks[C].EndLine > State.LogicBlocks[B].EndLine) or
           (C < B) then
        begin
          Span := State.LogicBlocks[C].EndLine - State.LogicBlocks[C].StartLine;
          if (Span < BestSpan) or ((Span = BestSpan) and (C < Best)) then
          begin
            Best := C;
            BestSpan := Span;
          end;
        end;
      end;
    end;
    NewParent[B] := Best;
  end;

  for B := 0 to High(State.LogicBlocks) do
  begin
    State.LogicBlocks[B].ParentIdx := NewParent[B];
    State.LogicBlocks[B].Children := nil;
    State.LogicBlocks[B].Depth := 0;
  end;
  for B := 0 to High(State.LogicBlocks) do
    if State.LogicBlocks[B].ParentIdx >= 0 then
    begin
      C := State.LogicBlocks[B].ParentIdx;
      SetLength(State.LogicBlocks[C].Children, Length(State.LogicBlocks[C].Children) + 1);
      State.LogicBlocks[C].Children[High(State.LogicBlocks[C].Children)] := B;
    end;

  Pass := 0;
  repeat
    Changed := False;
    Inc(Pass);
    for B := 0 to High(State.LogicBlocks) do
      if State.LogicBlocks[B].ParentIdx >= 0 then
      begin
        D := State.LogicBlocks[State.LogicBlocks[B].ParentIdx].Depth + 1;
        if State.LogicBlocks[B].Depth <> D then
        begin
          State.LogicBlocks[B].Depth := D;
          Changed := True;
        end;
      end;
  until (not Changed) or (Pass > Length(State.LogicBlocks) + 2);
end;

procedure RecordForwardDecl(const AName, AKind, ASig: string;
FileIdx, LineNum: Integer; RequiresImpl: Boolean);
var
I, N: Integer;
begin
for I := 0 to High(State.Forwards) do
if SameText(State.Forwards[I].Name, AName) and
(State.Forwards[I].FileIdx = FileIdx) and
(State.Forwards[I].Line = LineNum) then
Exit;

N := Length(State.Forwards);
SetLength(State.Forwards, N + 1);
State.Forwards[N].Name := AName;
State.Forwards[N].Kind := AKind;
State.Forwards[N].Signature := ASig;
State.Forwards[N].FileIdx := FileIdx;
State.Forwards[N].Line := LineNum;
State.Forwards[N].RequiresImpl := RequiresImpl;
State.Forwards[N].ImplFileIdx := -1;
State.Forwards[N].ImplLine := 0;
end;

procedure LinkForwardImplementation(const AName: string; ImplFile, ImplLine: Integer);
var
I, DotPos: Integer;
ShortName: string;
begin
DotPos := LastDelimiter('.', AName);
if DotPos > 0 then
ShortName := Copy(AName, DotPos + 1, MaxInt)
else
ShortName := AName;

for I := 0 to High(State.Forwards) do
if (State.Forwards[I].ImplFileIdx < 0) and
(SameText(State.Forwards[I].Name, AName) or
SameText(State.Forwards[I].Name, ShortName)) then
begin
State.Forwards[I].ImplFileIdx := ImplFile;
State.Forwards[I].ImplLine := ImplLine;
end;
end;

{ ============================================================================
Recursive Pascal Parser (Include Directives, Declarations, Routines & Blocks)
============================================================================ }

type
TParseContext = record
InInterface: Boolean;
ActiveRoutineIdx: Integer;
ActiveBlockIdx: Integer;
ActiveFiles: TIntArray;
end;

procedure ParseFileTokens(FileIdx: Integer; var Ctx: TParseContext); forward;

procedure ResolveUsesNames(const Toks: TRawTokenArray; StartIdx, EndIdx,
  FileIdx: Integer; var Ctx: TParseContext);
var
  I, J, K, UIdx: Integer;
  Name, Resolved: string;
  Edge: TTreeEdge;
  SubCtx: TParseContext;
  Seen: Boolean;
begin
  if not Options.UnitsMode then Exit;
  I := StartIdx;
  while I <= EndIdx do
  begin
    if Toks[I].Kind <> tkIdent then
    begin
      Inc(I);
      Continue;
    end;
    if Toks[I].Lower = 'in' then Break;
    Name := Toks[I].Text;
    J := I;
    while (J + 2 <= EndIdx) and (Toks[J + 1].Text = '.') and
          (Toks[J + 2].Kind = tkIdent) do
    begin
      Name := Name + '.' + Toks[J + 2].Text;
      Inc(J, 2);
    end;
    I := J + 1;
    if Name = '' then Continue;

    Resolved := ResolveUnitFile(Name, FileIdx);
    if Resolved = '' then
    begin
      AddDiagnostic(FileIdx, Toks[StartIdx].Line, Toks[StartIdx].Col, EXIT_BIT_WARNING,
        'Unit not found: "' + Name + '" (add -Fu<dir> or --units)');
      Continue;
    end;

    Edge.ParentFileIdx := FileIdx;
    Edge.ParentLine := Toks[StartIdx].Line;
    Edge.EdgeKind := 'uses';
    Edge.TargetDisplay := Name;
    Edge.InsideRoutine := '';
    Edge.AlreadyIncluded := False;
    Edge.Resolution := 'unit';

    UIdx := FindLoadedFile(Resolved);
    if UIdx < 0 then
      UIdx := LoadAndLexFile(Resolved, Name, FileIdx, Toks[StartIdx].Line);
    Edge.TargetFileIdx := UIdx;
    SetLength(State.TreeEdges, Length(State.TreeEdges) + 1);
    State.TreeEdges[High(State.TreeEdges)] := Edge;
    if UIdx < 0 then Continue;

    Seen := False;
    for K := 0 to High(UnitStack) do
      if UnitStack[K] = UIdx then Seen := True;
    if Seen then
    begin
      AddDiagnostic(FileIdx, Toks[StartIdx].Line, Toks[StartIdx].Col, EXIT_BIT_WARNING,
        'Circular unit reference: "' + Name + '"');
      Continue;
    end;
    Seen := False;
    for K := 0 to High(ParsedUnits) do
      if ParsedUnits[K] = UIdx then Seen := True;
    if Seen then Continue;

    SetLength(UnitStack, Length(UnitStack) + 1);
    UnitStack[High(UnitStack)] := UIdx;
    FillChar(SubCtx, SizeOf(SubCtx), 0);
    SubCtx.InInterface := False;
    SubCtx.ActiveRoutineIdx := -1;
    SubCtx.ActiveBlockIdx := -1;
    SetLength(SubCtx.ActiveFiles, Length(Ctx.ActiveFiles) + 1);
    for K := 0 to High(Ctx.ActiveFiles) do
      SubCtx.ActiveFiles[K] := Ctx.ActiveFiles[K];
    SubCtx.ActiveFiles[High(SubCtx.ActiveFiles)] := UIdx;
    ParseFileTokens(UIdx, SubCtx);
    SetLength(UnitStack, Length(UnitStack) - 1);
    SetLength(ParsedUnits, Length(ParsedUnits) + 1);
    ParsedUnits[High(ParsedUnits)] := UIdx;
  end;
end;

procedure AddDefineName(const N: string);
var I: Integer;
begin
  if N = '' then Exit;
  for I := 0 to High(DefineNames) do if SameText(DefineNames[I], N) then Exit;
  SetLength(DefineNames, Length(DefineNames) + 1);
  DefineNames[High(DefineNames)] := N;
end;

function IsDefineSet(const N: string): Boolean;
var I: Integer;
begin
  Result := False;
  for I := 0 to High(DefineNames) do
    if SameText(DefineNames[I], N) then begin Result := True; Exit; end;
end;

function EvalCondKeyword(const Kw, Arg: string): Boolean;
var LArg, N: string; P: Integer;
begin
  LArg := LowerCase(Trim(Arg));
  if Kw = 'ifdef' then
    Result := IsDefineSet(Arg)
  else if Kw = 'ifndef' then
    Result := not IsDefineSet(Arg)
  else if Kw = 'if' then
  begin
    if Copy(LArg, 1, 8) = 'defined(' then
    begin
      P := Pos(')', LArg);
      if P > 8 then N := Trim(Copy(Arg, 9, P - 9)) else N := '';
      Result := IsDefineSet(N);
    end
    else if Copy(LArg, 1, 12) = 'not defined(' then
    begin
      P := Pos(')', LArg);
      if P > 12 then N := Trim(Copy(Arg, 13, P - 13)) else N := '';
      Result := not IsDefineSet(N);
    end
    else
      Result := True;
  end
  else
    Result := True;
end;

function CondParentActive: Boolean;
var I: Integer;
begin
  Result := True;
  for I := 0 to High(CondStack) do
    if not CondStack[I].Active then begin Result := False; Exit; end;
end;

{ True when a source line sits in a branch disabled by conditional directives. }
function IsLineCondInactive(FIdx, Line: Integer): Boolean;
var
  Toks: TRawTokenArray;
  I, P, Len, K: Integer;
  S, Kw, Arg: string;
  TakenArr, ActiveArr: TBoolArray;
  ParentActive, Cond: Boolean;
begin
  Result := False;
  if (FIdx < 0) or (FIdx >= Length(State.Files)) then Exit;
  Toks := State.Files[FIdx].Tokens;
  SetLength(TakenArr, 0);
  SetLength(ActiveArr, 0);
  for I := 0 to High(Toks) do
  begin
    if Toks[I].Line > Line then Break;
    if Toks[I].Kind <> tkDirective then Continue;
    S := Trim(Toks[I].Text);
    Len := Length(S);
    P := 1;
    while (P <= Len) and IsAlnumOrUnderscore(S[P]) do Inc(P);
    Kw := LowerCase(Copy(S, 1, P - 1));
    Arg := Trim(Copy(S, P, MaxInt));
    ParentActive := True;
    for K := 0 to High(ActiveArr) do
      if not ActiveArr[K] then begin ParentActive := False; Break; end;
    if (Kw = 'ifdef') or (Kw = 'ifndef') or (Kw = 'if') or (Kw = 'ifopt') then
    begin
      Cond := EvalCondKeyword(Kw, Arg);
      SetLength(TakenArr, Length(TakenArr) + 1);
      SetLength(ActiveArr, Length(ActiveArr) + 1);
      TakenArr[High(TakenArr)] := Cond;
      ActiveArr[High(ActiveArr)] := ParentActive and Cond;
    end
    else if (Kw = 'elseif') or (Kw = 'elif') then
    begin
      if Length(ActiveArr) > 0 then
      begin
        Cond := EvalCondKeyword(Kw, Arg);
        ActiveArr[High(ActiveArr)] := ParentActive and
          (not TakenArr[High(TakenArr)]) and Cond;
        if Cond then TakenArr[High(TakenArr)] := True;
      end;
    end
    else if Kw = 'else' then
    begin
      if Length(ActiveArr) > 0 then
      begin
        ActiveArr[High(ActiveArr)] := ParentActive and
          (not TakenArr[High(TakenArr)]);
        TakenArr[High(TakenArr)] := True;
      end;
    end
    else if (Kw = 'endif') or (Kw = 'ifend') then
    begin
      if Length(ActiveArr) > 0 then
      begin
        SetLength(ActiveArr, Length(ActiveArr) - 1);
        SetLength(TakenArr, Length(TakenArr) - 1);
      end;
    end;
  end;
  for K := 0 to High(ActiveArr) do
    if not ActiveArr[K] then begin Result := True; Exit; end;
end;

procedure HandleCompilerDirective(FileIdx: Integer; const Tok: TRawToken;
var Ctx: TParseContext);
var
S, Kw, Arg, Resolved, Disp: string;
  P, Len, ExistingIdx, TargetIdx, A: Integer;
  Cond: Boolean;
Edge: TTreeEdge;
SubCtx: TParseContext;
CondItem: TCondIfItem;
begin
S := Trim(Tok.Text);
if S = '' then
Exit;

Len := Length(S);
P := 1;
while (P <= Len) and IsAlnumOrUnderscore(S[P]) do
Inc(P);
Kw := LowerCase(Copy(S, 1, P - 1));
Arg := Trim(Copy(S, P, MaxInt));

{ Conditional compilation tracking }
if (Kw = 'ifdef') or (Kw = 'ifndef') or (Kw = 'if') or (Kw = 'ifopt') then
begin
  CondItem.Directive := '{$' + Copy(S, 1, P - 1) + '}';
  CondItem.SeenElse := False;
  CondItem.Taken := EvalCondKeyword(Kw, Arg);
  CondItem.Active := CondParentActive and CondItem.Taken;
  CondItem.FileIdx := FileIdx;
  CondItem.Line := Tok.Line;
  CondItem.Col := Tok.Col;
  CondItem.Snippet := GetLineSnippet(FileIdx, Tok.Line);
  SetLength(CondStack, Length(CondStack) + 1);
  CondStack[High(CondStack)] := CondItem;
  Exit;
end;

if (Kw = 'elseif') or (Kw = 'elif') then
begin
  if (Length(CondStack) = 0) or CondStack[High(CondStack)].SeenElse then
    AddDiagnostic(FileIdx, Tok.Line, Tok.Col, EXIT_BIT_STRUCTURAL,
      'Misplaced {$' + Kw + '} without open {$IFDEF}/{$IF}')
  else
  begin
    Cond := EvalCondKeyword(Kw, Arg);
    CondStack[High(CondStack)].Active := CondParentActive and
      (not CondStack[High(CondStack)].Taken) and Cond;
    if Cond then CondStack[High(CondStack)].Taken := True;
  end;
  Exit;
end;

if Kw = 'else' then
begin
  if (Length(CondStack) = 0) or CondStack[High(CondStack)].SeenElse then
    AddDiagnostic(FileIdx, Tok.Line, Tok.Col, EXIT_BIT_STRUCTURAL,
      'Misplaced {$ELSE} without matching {$IFDEF}/{$IF}')
  else
  begin
    CondStack[High(CondStack)].Active := CondParentActive and
      (not CondStack[High(CondStack)].Taken);
    CondStack[High(CondStack)].Taken := True;
    CondStack[High(CondStack)].SeenElse := True;
  end;
  Exit;
end;

if (Kw = 'endif') or (Kw = 'ifend') then
begin
  if Length(CondStack) = 0 then
    AddDiagnostic(FileIdx, Tok.Line, Tok.Col, EXIT_BIT_STRUCTURAL,
      'Unexpected {$ENDIF} with no matching {$IFDEF}/{$IF}')
  else
    SetLength(CondStack, Length(CondStack) - 1);
  Exit;
end;

{ Symbol definitions }
if (Kw = 'define') and (Arg <> '') then
begin

  AddDefineName(Arg);
  Exit;
end;
if (Kw = 'undef') and (Arg <> '') then
begin
  for A := 0 to High(DefineNames) do
    if SameText(DefineNames[A], Arg) then
    begin
      DefineNames[A] := DefineNames[High(DefineNames)];
      SetLength(DefineNames, Length(DefineNames) - 1);
      Break;
    end;
  Exit;
end;

{ Include directives: $I filename or $INCLUDE filename (ignoring $I+ / $I-) }
if ((Kw = 'i') or (Kw = 'include')) and (Arg <> '') and
(Arg <> '+') and (Arg <> '-') then
begin
if (Ctx.ActiveRoutineIdx >= 0) and (Ctx.ActiveRoutineIdx < Length(State.Routines)) then
AppendUsage(State.Routines[Ctx.ActiveRoutineIdx].Includes,
'{$' + Copy(S, 1, P - 1) + ' ' + Arg + '}', FileIdx, Tok.Line);

Resolved := ResolveIncludeFile(Arg, FileIdx);
if Resolved = '' then
begin
  Edge.ParentFileIdx := FileIdx;
  Edge.ParentLine := Tok.Line;
  Edge.EdgeKind := '{$' + Copy(S, 1, P - 1) + '}';
  Edge.TargetDisplay := Arg;
  Edge.TargetFileIdx := -1;
  if Ctx.ActiveRoutineIdx >= 0 then
    Edge.InsideRoutine := State.Routines[Ctx.ActiveRoutineIdx].Name
  else
    Edge.InsideRoutine := '';
  Edge.AlreadyIncluded := False;
  SetLength(State.TreeEdges, Length(State.TreeEdges) + 1);
  State.TreeEdges[High(State.TreeEdges)] := Edge;

  AddDiagnostic(FileIdx, Tok.Line, Tok.Col, EXIT_BIT_INCLUDE,
    'Include file not found: "' + Arg + '"');
  Exit;
end;

ExistingIdx := FindLoadedFile(Resolved);
if ExistingIdx >= 0 then
  for A := 0 to High(Ctx.ActiveFiles) do
    if Ctx.ActiveFiles[A] = ExistingIdx then
    begin
      AddDiagnostic(FileIdx, Tok.Line, Tok.Col, EXIT_BIT_INCLUDE,
        'Circular include directive: "' + Arg + '"');
      Exit;
    end;

Disp := MakeRelativeDisplay(Resolved);
TargetIdx := LoadAndLexFile(Resolved, Disp, FileIdx, Tok.Line);
if TargetIdx < 0 then
  Exit;

Edge.ParentFileIdx := FileIdx;
Edge.ParentLine := Tok.Line;
Edge.EdgeKind := '{$' + Copy(S, 1, P - 1) + '}';
Edge.TargetDisplay := State.Files[TargetIdx].DisplayName;
Edge.TargetFileIdx := TargetIdx;
if Ctx.ActiveRoutineIdx >= 0 then
  Edge.InsideRoutine := State.Routines[Ctx.ActiveRoutineIdx].Name
else
  Edge.InsideRoutine := '';
Edge.AlreadyIncluded := (ExistingIdx >= 0);
SetLength(State.TreeEdges, Length(State.TreeEdges) + 1);
State.TreeEdges[High(State.TreeEdges)] := Edge;

SubCtx := Ctx;
SubCtx.ActiveFiles := Copy(Ctx.ActiveFiles);
SetLength(SubCtx.ActiveFiles, Length(SubCtx.ActiveFiles) + 1);
SubCtx.ActiveFiles[High(SubCtx.ActiveFiles)] := TargetIdx;
ParseFileTokens(TargetIdx, SubCtx);
Ctx.InInterface := SubCtx.InInterface;


end;
end;

procedure ParseParamOrVarGroup(const Toks: TRawTokenArray; StartIdx, EndIdx,
FileIdx: Integer; var OutList: TUsageItemArray);
var
I, ColonPos, EqPos, K, NameLimit: Integer;
TypeStr, ValStr: string;
Names: TStringArray;
NameLines: TIntArray;
begin
if StartIdx > EndIdx then
Exit;

I := StartIdx;
if (I <= EndIdx) and
((Toks[I].Lower = 'var') or (Toks[I].Lower = 'const') or
(Toks[I].Lower = 'out') or (Toks[I].Lower = 'constref')) then
Inc(I);

ColonPos := -1;
EqPos := -1;
for K := I to EndIdx do
begin
if (Toks[K].Text = ':') and (ColonPos < 0) then
ColonPos := K
else if (Toks[K].Text = '=') and (EqPos < 0) then
EqPos := K;
end;

if ColonPos >= 0 then
NameLimit := ColonPos - 1
else if EqPos >= 0 then
NameLimit := EqPos - 1
else
NameLimit := EndIdx;

Names := nil;
NameLines := nil;
for K := I to NameLimit do
if Toks[K].Kind = tkIdent then
begin
SetLength(Names, Length(Names) + 1);
Names[High(Names)] := Toks[K].Text;
SetLength(NameLines, Length(NameLines) + 1);
NameLines[High(NameLines)] := Toks[K].Line;
end;

if (ColonPos >= 0) and (ColonPos + 1 <= EndIdx) then
begin
if EqPos > ColonPos then
TypeStr := FormatExprSlice(Toks, ColonPos + 1, EqPos - 1, -1, False)
else
TypeStr := FormatExprSlice(Toks, ColonPos + 1, EndIdx, -1, False);
end
else if EqPos >= 0 then
begin
ValStr := FormatExprSlice(Toks, EqPos + 1, EndIdx, -1, False);
TypeStr := 'const = ' + ValStr;
end
else
TypeStr := 'untyped';

for K := 0 to High(Names) do
AppendUsage(OutList, Names[K], FileIdx, NameLines[K], TypeStr);
end;

procedure ParseParamList(const Toks: TRawTokenArray; OpenParen, CloseParen,
FileIdx: Integer; var ParamsOut: TUsageItemArray);
var
I, SegStart, Depth: Integer;
begin
I := OpenParen + 1;
while I < CloseParen do
begin
SegStart := I;
Depth := 0;
while I < CloseParen do
begin
if (Toks[I].Text = '(') or (Toks[I].Text = '[') then
Inc(Depth)
else if (Toks[I].Text = ')') or (Toks[I].Text = ']') then
Dec(Depth)
else if (Depth = 0) and (Toks[I].Text = ';') then
Break;
Inc(I);
end;
if SegStart <= I - 1 then
ParseParamOrVarGroup(Toks, SegStart, I - 1, FileIdx, ParamsOut);
if (I < CloseParen) and (Toks[I].Text = ';') then
Inc(I);
end;
end;

procedure ParseRoutineHeadAndDirectives(const Toks: TRawTokenArray; var Idx: Integer;
FileIdx: Integer; out OutKind, OutName, OutRetType, OutFullSig: string;
out OutParams: TUsageItemArray; out OutIsExternal, OutIsForward: Boolean);
var
Count, StartIdx, CloseP, ColonPos, RetEnd, SemiPos, DirEnd, DirDepth: Integer;
DirLow: string;
begin
Count := Length(Toks);
StartIdx := Idx;
OutKind := Toks[Idx].Lower;
Inc(Idx);

OutName := '';
while (Idx < Count) and (Toks[Idx].Kind = tkIdent) do
begin
if OutName <> '' then
OutName := OutName + '.';
OutName := OutName + Toks[Idx].Text;
Inc(Idx);
if (Idx < Count) and (Toks[Idx].Text = '.') then
Inc(Idx)
else
Break;
end;
if (OutName = '') and (Idx < Count) and (Toks[Idx].Kind = tkSymbol) then
begin
OutName := Toks[Idx].Text;
Inc(Idx);
end;

OutParams := nil;
if (Idx < Count) and (Toks[Idx].Text = '(') then
begin
CloseP := FindMatchingClose(Toks, Idx, '(', ')');
if CloseP < Count then
begin
ParseParamList(Toks, Idx, CloseP, FileIdx, OutParams);
Idx := CloseP + 1;
end
else
Idx := Count;
end;

OutRetType := '';
if (Idx < Count) and (Toks[Idx].Text = ':') then
begin
ColonPos := Idx;
Inc(Idx);
while (Idx < Count) and (Toks[Idx].Text <> ';') and
(Toks[Idx].Lower <> 'begin') and (Toks[Idx].Lower <> 'var') and
(Toks[Idx].Lower <> 'const') and (Toks[Idx].Lower <> 'type') and
(Toks[Idx].Lower <> 'forward') and (Toks[Idx].Lower <> 'external') do
Inc(Idx);
RetEnd := Idx - 1;
if ColonPos + 1 <= RetEnd then
OutRetType := FormatExprSlice(Toks, ColonPos + 1, RetEnd, -1, False);
end;

SemiPos := Idx;
if (Idx < Count) and (Toks[Idx].Text = ';') then
Inc(Idx);

OutFullSig := FormatExprSlice(Toks, StartIdx, MaxIntVal(StartIdx, SemiPos - 1), -1, False);
OutIsExternal := False;
OutIsForward := False;

{ Consume trailing routine directives: forward; external; inline; virtual; override; overload; cdecl; stdcall; }
while Idx < Count do
begin
DirLow := Toks[Idx].Lower;
{ A visibility keyword introducing the next class member (e.g. 'public'
  before a method declaration) is not a routine directive. Consuming it
  here would skip the following method's header, including any ';' inside
  its parameter groups, and could hide the class's closing 'end'. }
if (DirLow = 'public') or (DirLow = 'private') or (DirLow = 'protected') or
   (DirLow = 'published') then
  if (Idx + 1 >= Count) or IsRoutineStarter(Toks[Idx + 1].Lower) then
    Break;
if (DirLow = 'forward') or (DirLow = 'external') or (DirLow = 'inline') or
(DirLow = 'virtual') or (DirLow = 'override') or (DirLow = 'abstract') or
(DirLow = 'overload') or (DirLow = 'reintroduce') or (DirLow = 'static') or
(DirLow = 'cdecl') or (DirLow = 'stdcall') or (DirLow = 'register') or
(DirLow = 'pascal') or (DirLow = 'safecall') or (DirLow = 'assembler') or
(DirLow = 'nostackframe') or (DirLow = 'deprecated') or (DirLow = 'public') then
begin
if DirLow = 'external' then
OutIsExternal := True;
if DirLow = 'forward' then
OutIsForward := True;
DirEnd := Idx;
DirDepth := 0;
{ Skip to the directive's terminating ';', ignoring ';' nested in
  parentheses/brackets so a directive argument cannot swallow the rest. }
while DirEnd < Count do
begin
  if (Toks[DirEnd].Text = '(') or (Toks[DirEnd].Text = '[') then
    Inc(DirDepth)
  else if (Toks[DirEnd].Text = ')') or (Toks[DirEnd].Text = ']') then
    Dec(DirDepth)
  else if (Toks[DirEnd].Text = ';') and (DirDepth <= 0) then
    Break;
  Inc(DirEnd);
end;
if DirEnd < Count then
Idx := DirEnd + 1
else
Idx := Count;
end
else
Break;
end;
end;

procedure SkipAttributeGroups(const Toks: TRawTokenArray; var Idx: Integer; Count: Integer);
var D: Integer;
begin
  while (Idx < Count) and (Toks[Idx].Text = '[') do
  begin
    D := 1; Inc(Idx);
    while (Idx < Count) and (D > 0) do
    begin
      if Toks[Idx].Text = '[' then Inc(D)
      else if Toks[Idx].Text = ']' then Dec(D);
      Inc(Idx);
    end;
  end;
end;

procedure ParseTypeSection(const Toks: TRawTokenArray; var Idx: Integer;
FileIdx: Integer; var Ctx: TParseContext);
var
  Count, TStartLine, K, EndIdx, MNameIdx, SubEnd, DCallEnd, D: Integer;
DCallLow: string;
TName, TKind, MKind, MName, MSig, MRet: string;
TD: TTypeDecl;
MItem: TMemberItem;
MParams: TUsageItemArray;
MExt, MFwd: Boolean;
begin
Count := Length(Toks);
Inc(Idx); { skip 'type' }

while Idx < Count do
begin
if Toks[Idx].Kind = tkDirective then
begin
HandleCompilerDirective(FileIdx, Toks[Idx], Ctx);
Inc(Idx);
Continue;
end;
if Toks[Idx].Kind = tkLexError then
begin
AddDiagnostic(FileIdx, Toks[Idx].Line, Toks[Idx].Col, EXIT_BIT_SYNTAX, Toks[Idx].Text);
Inc(Idx);
Continue;
end;
SkipAttributeGroups(Toks, Idx, Count);
if Idx >= Count then Break;
if (Idx < Count) and (Toks[Idx].Lower = 'generic') then Inc(Idx);


if (Toks[Idx].Kind <> tkIdent) or IsPascalKeyword(Toks[Idx].Lower) then
  Break;

TName := Toks[Idx].Text;
TStartLine := Toks[Idx].Line;
Inc(Idx);
{ Generic type parameters: TGen<T, U> = class ... }
if (Idx < Count) and (Toks[Idx].Text = '<') then
begin
  D := 1; Inc(Idx);
  while (Idx < Count) and (D > 0) do
  begin
    if Toks[Idx].Text = '<' then Inc(D)
    else if Toks[Idx].Text = '>' then Dec(D);
    Inc(Idx);
  end;
end;
if (Idx >= Count) or (Toks[Idx].Text <> '=') then
  Break;
Inc(Idx); { skip '=' }

if (Idx < Count) and (Toks[Idx].Lower = 'packed') then
  Inc(Idx);

TD.Name := TName;
TD.FileIdx := FileIdx;
TD.StartLine := TStartLine;
TD.EndLine := TStartLine;
TD.IsForward := False;
TD.Fields := nil;
TD.Methods := nil;

if (Idx < Count) and
   ((Toks[Idx].Lower = 'record') or (Toks[Idx].Lower = 'class') or
    (Toks[Idx].Lower = 'object') or (Toks[Idx].Lower = 'interface')) then
begin
  TKind := Toks[Idx].Lower;
  TD.Kind := TKind;
  Inc(Idx);

  { Forward class/interface declaration: TMyClass = class; }
  if (Idx < Count) and (Toks[Idx].Text = ';') then
  begin
    TD.IsForward := True;
    TD.EndLine := Toks[Idx].Line;
    SetLength(State.Types, Length(State.Types) + 1);
    State.Types[High(State.Types)] := TD;
    Inc(Idx);
    Continue;
  end;

  { Optional ancestor list (TBase) }
  if (Idx < Count) and (Toks[Idx].Text = '(') then
  begin
    EndIdx := FindMatchingClose(Toks, Idx, '(', ')');
    if EndIdx < Count then
      Idx := EndIdx + 1
    else
      Idx := Count;
  end;

  { Parse fields and methods up to matching 'end;' }
  while (Idx < Count) and (Toks[Idx].Lower <> 'end') do
  begin
    if Toks[Idx].Kind = tkDirective then
    begin
      HandleCompilerDirective(FileIdx, Toks[Idx], Ctx);
      Inc(Idx);
      Continue;
    end;
    if (Toks[Idx].Lower = 'private') or (Toks[Idx].Lower = 'protected') or
       (Toks[Idx].Lower = 'public') or (Toks[Idx].Lower = 'published') or
       (Toks[Idx].Lower = 'strict') then
    begin
      Inc(Idx);
      Continue;
    if (Toks[Idx].Lower = 'var') or (Toks[Idx].Lower = 'threadvar') or
       (Toks[Idx].Lower = 'const') then
    begin Inc(Idx); Continue; end;
    if (Toks[Idx].Lower = 'class') and (Idx + 1 < Count) and
       (Toks[Idx + 1].Lower = 'var') then
    begin Inc(Idx, 2); Continue; end;
    SkipAttributeGroups(Toks, Idx, Count);
    if Idx >= Count then Break;
    end;
    if (Toks[Idx].Lower = 'class') and (Idx + 1 < Count) and
       IsRoutineStarter(Toks[Idx + 1].Lower) then
      Inc(Idx);

    if IsRoutineStarter(Toks[Idx].Lower) then
    begin
      MNameIdx := Toks[Idx].Line;
      ParseRoutineHeadAndDirectives(Toks, Idx, FileIdx, MKind, MName, MRet, MSig, MParams, MExt, MFwd);
      MItem.Name := MName;
      MItem.Detail := MSig;
      MItem.ValueExpr := '';
      MItem.IsConst := False;
      MItem.FileIdx := FileIdx;
      MItem.Line := MNameIdx;
      SetLength(TD.Methods, Length(TD.Methods) + 1);
      TD.Methods[High(TD.Methods)] := MItem;
      RecordForwardDecl(TName + '.' + MName, MKind, MSig, FileIdx, MNameIdx, not MExt);
      Continue;
    end;

    if Toks[Idx].Lower = 'property' then
    begin
      SubEnd := Idx + 1;
      while (SubEnd < Count) and (Toks[SubEnd].Text <> ';') do
        Inc(SubEnd);
      if Idx + 1 < SubEnd then
      begin
        MItem.Name := Toks[Idx + 1].Text;
        MItem.Detail := FormatExprSlice(Toks, Idx, SubEnd - 1, -1, False);
        MItem.ValueExpr := '';
        MItem.IsConst := False;
        MItem.FileIdx := FileIdx;
        MItem.Line := Toks[Idx].Line;
        SetLength(TD.Fields, Length(TD.Fields) + 1);
        TD.Fields[High(TD.Fields)] := MItem;
      end;
      if SubEnd < Count then
        Idx := SubEnd + 1
      else
        Idx := Count;
      Continue;
    end;

    { Field declaration group up to ';' or 'end' }
    SubEnd := Idx;
    K := 0;
    while SubEnd < Count do
    begin
      if (Toks[SubEnd].Text = '(') or (Toks[SubEnd].Text = '[') then
        Inc(K)
      else if (Toks[SubEnd].Text = ')') or (Toks[SubEnd].Text = ']') then
        Dec(K)
      else if (K = 0) and ((Toks[SubEnd].Text = ';') or (Toks[SubEnd].Lower = 'end')) then
        Break;
      Inc(SubEnd);
    end;
    if Idx <= SubEnd - 1 then
    begin
      MParams := nil;
      ParseParamOrVarGroup(Toks, Idx, SubEnd - 1, FileIdx, MParams);
      for K := 0 to High(MParams) do
      begin
        MItem.Name := MParams[K].Name;
        MItem.Detail := MParams[K].Detail;
        MItem.ValueExpr := '';
        MItem.IsConst := False;
        MItem.FileIdx := FileIdx;
        MItem.Line := MParams[K].Sites[0].Line;
        SetLength(TD.Fields, Length(TD.Fields) + 1);
        TD.Fields[High(TD.Fields)] := MItem;
      end;
    end;
    if (SubEnd < Count) and (Toks[SubEnd].Text = ';') then
      Idx := SubEnd + 1
    else if SubEnd = Idx then
      Inc(Idx)
    else
      Idx := SubEnd;
  end;

  if (Idx < Count) and (Toks[Idx].Lower = 'end') then
  begin
    TD.EndLine := Toks[Idx].Line;
    Inc(Idx);
  end;
  if (Idx < Count) and (Toks[Idx].Text = ';') then
  begin
    SetLocation(LastGoodStmt, 'type definition', FileIdx, Toks[Idx].Line, Toks[Idx].Col);
    Inc(Idx);
  end;
  SetLength(State.Types, Length(State.Types) + 1);
  State.Types[High(State.Types)] := TD;
  AddLogicBlock(bkType, TD.Kind + ' ' + TD.Name, -1, -1, FileIdx, TD.StartLine, FileIdx, TD.EndLine);
end
else
begin
  { Simple type alias, enum, subrange, array, or pointer type up to ';' }
  SubEnd := Idx;
  K := 0;
  while SubEnd < Count do
  begin
    if (Toks[SubEnd].Text = '(') or (Toks[SubEnd].Text = '[') then
      Inc(K)
    else if (Toks[SubEnd].Text = ')') or (Toks[SubEnd].Text = ']') then
      Dec(K)
    else if (K = 0) and (Toks[SubEnd].Text = ';') then
      Break;
    Inc(SubEnd);
  end;
  if Idx <= SubEnd - 1 then
  begin
    if Toks[Idx].Text = '(' then
      TD.Kind := 'enum ' + FormatExprSlice(Toks, Idx, SubEnd - 1, -1, False)
    else
      TD.Kind := FormatExprSlice(Toks, Idx, SubEnd - 1, -1, False);
  end
  else
    TD.Kind := 'type';
  if SubEnd < Count then
  begin
    TD.EndLine := Toks[SubEnd].Line;
    SetLocation(LastGoodStmt, 'type alias', FileIdx, Toks[SubEnd].Line, Toks[SubEnd].Col);
    Idx := SubEnd + 1;
  end
  else
    Idx := Count;
  { A procedural type may carry calling-convention directives after its first
    ';' (e.g. 'T = function(...): Integer; stdcall;'). Without consuming them,
    the next token is read as a bogus type/routine declaration and the type
    section loses sync with the rest of the unit. }
  DCallLow := LowerCase(TD.Kind);
  if (Pos('function', DCallLow) > 0) or (Pos('procedure', DCallLow) > 0) then
    while Idx < Count do
    begin
      DCallLow := Toks[Idx].Lower;
      if not ((DCallLow = 'stdcall') or (DCallLow = 'cdecl') or
              (DCallLow = 'register') or (DCallLow = 'pascal') or
              (DCallLow = 'safecall') or (DCallLow = 'inline') or
              (DCallLow = 'assembler') or (DCallLow = 'nostackframe') or
              (DCallLow = 'external') or (DCallLow = 'forward') or
              (DCallLow = 'deprecated') or (DCallLow = 'varargs')) then
        Break;
      DCallEnd := Idx;
      while (DCallEnd < Count) and (Toks[DCallEnd].Text <> ';') do Inc(DCallEnd);
      if DCallEnd < Count then Idx := DCallEnd + 1 else Idx := Count;
    end;
  SetLength(State.Types, Length(State.Types) + 1);
  State.Types[High(State.Types)] := TD;
end;


end;
end;

procedure ParseVarOrConstSection(const Toks: TRawTokenArray; var Idx: Integer;
FileIdx: Integer; IsConstSec: Boolean; ActiveRtnIdx: Integer; var Ctx: TParseContext);
var
Count, SubEnd, Depth, K: Integer;
Items: TUsageItemArray;
GM: TMemberItem;
begin
Count := Length(Toks);
Inc(Idx); { skip 'var' / 'const' / 'resourcestring' / 'threadvar' }

while Idx < Count do
begin
if Toks[Idx].Kind = tkDirective then
begin
HandleCompilerDirective(FileIdx, Toks[Idx], Ctx);
Inc(Idx);
Continue;
end;
if Toks[Idx].Kind = tkLexError then
begin
AddDiagnostic(FileIdx, Toks[Idx].Line, Toks[Idx].Col, EXIT_BIT_SYNTAX, Toks[Idx].Text);
Inc(Idx);
Continue;
end;
if (Toks[Idx].Kind <> tkIdent) or IsPascalKeyword(Toks[Idx].Lower) then
Break;

SubEnd := Idx;
Depth := 0;
while SubEnd < Count do
begin
  if (Toks[SubEnd].Text = '(') or (Toks[SubEnd].Text = '[') then
    Inc(Depth)
  else if (Toks[SubEnd].Text = ')') or (Toks[SubEnd].Text = ']') then
    Dec(Depth)
  else if (Depth = 0) and (Toks[SubEnd].Text = ';') then
    Break;
  Inc(SubEnd);
end;

if Idx <= SubEnd - 1 then
begin
  Items := nil;
  ParseParamOrVarGroup(Toks, Idx, SubEnd - 1, FileIdx, Items);
  for K := 0 to High(Items) do
  begin
    if ActiveRtnIdx >= 0 then
      AppendUsage(State.Routines[ActiveRtnIdx].Locals, Items[K].Name,
        FileIdx, Items[K].Sites[0].Line, Items[K].Detail)
    else
    begin
      GM.Name := Items[K].Name;
      GM.Detail := Items[K].Detail;
      GM.ValueExpr := '';
      GM.IsConst := IsConstSec;
      GM.FileIdx := FileIdx;
      GM.Line := Items[K].Sites[0].Line;
      SetLength(State.Globals, Length(State.Globals) + 1);
      State.Globals[High(State.Globals)] := GM;
    end;
  end;
end;

if SubEnd < Count then
begin
  SetLocation(LastGoodStmt, 'declaration', FileIdx, Toks[SubEnd].Line, Toks[SubEnd].Col);
  Idx := SubEnd + 1;
end
else
  Idx := Count;


end;
end;

procedure AnalyzeStmtTokens(RtnIdx, FileIdx: Integer; const Toks: TRawTokenArray;
StartIdx, EndIdx: Integer);
var
I, Q, CloseP, CloseB, RhsStart, RhsEnd, D, K, IdLine: Integer;
Chain, VType, FmtVar, RhsFmt, ArgsFmt: string;
HadSubscript: Boolean;
Ctx: TParseContext;
begin
if (RtnIdx < 0) or (RtnIdx >= Length(State.Routines)) then
Exit;

I := StartIdx;
while I <= EndIdx do
begin
if Toks[I].Kind in [tkDirective, tkLexError] then
begin
if Toks[I].Kind = tkDirective then
begin
  HandleCompilerDirective(FileIdx, Toks[I], Ctx);
end;
Inc(I);
Continue;
end;

if (Toks[I].Kind = tkIdent) and IsPascalKeyword(Toks[I].Lower) then
begin
  Inc(I);
  Continue;
end;

if (Toks[I].Kind = tkIdent) and (not IsPascalKeyword(Toks[I].Lower)) then
begin
  IdLine := Toks[I].Line;
  Chain := Toks[I].Text;
  Q := I + 1;
  HadSubscript := False;

  while Q <= EndIdx do
  begin
    if (Q + 1 <= EndIdx) and (Toks[Q].Text = '.') and (Toks[Q + 1].Kind = tkIdent) then
    begin
      Chain := Chain + '.' + Toks[Q + 1].Text;
      Inc(Q, 2);
    end
    else if Toks[Q].Text = '^' then
    begin
      Chain := Chain + '^';
      Inc(Q);
    end
    else if Toks[Q].Text = '[' then
    begin
      CloseB := FindMatchingClose(Toks, Q, '[', ']');
      if (CloseB <= EndIdx) and (Q + 1 <= CloseB - 1) then
        AnalyzeStmtTokens(RtnIdx, FileIdx, Toks, Q + 1, CloseB - 1);
      HadSubscript := True;
      if CloseB <= EndIdx then
        Q := CloseB + 1
      else
        Q := EndIdx + 1;
    end
    else
      Break;
  end;

  { Routine call or typecast: Ident(args) }
  if (Q <= EndIdx) and (Toks[Q].Text = '(') and (not HadSubscript) then
  begin
    CloseP := FindMatchingClose(Toks, Q, '(', ')');
    if CloseP <= EndIdx then
    begin
      if Q + 1 <= CloseP - 1 then
      begin
        ArgsFmt := FormatExprSlice(Toks, Q + 1, CloseP - 1, RtnIdx, True);
        AppendUsage(State.Routines[RtnIdx].Calls, 'call ' + Chain + ': ' + ArgsFmt,
          FileIdx, IdLine);
        AnalyzeStmtTokens(RtnIdx, FileIdx, Toks, Q + 1, CloseP - 1);
      end
      else
        AppendUsage(State.Routines[RtnIdx].Calls, 'call ' + Chain, FileIdx, IdLine);
      I := CloseP + 1;
      Continue;
    end;
  end;

  VType := ResolveVarType(RtnIdx, Chain);
  FmtVar := Chain;
  if HadSubscript then
    FmtVar := FmtVar + '[]';
  if VType <> '' then
    FmtVar := FmtVar + ':' + VType;

  { Assignment: Target := Expr }
  if (Q <= EndIdx) and IsAssignSymbol(Toks[Q].Text) then
  begin
    AppendUsage(State.Routines[RtnIdx].Vars, FmtVar, FileIdx, IdLine, 'write');
    RhsStart := Q + 1;
    RhsEnd := EndIdx;
    D := 0;
    for K := RhsStart to EndIdx do
    begin
      if (Toks[K].Text = '(') or (Toks[K].Text = '[') then
        Inc(D)
      else if (Toks[K].Text = ')') or (Toks[K].Text = ']') then
        Dec(D)
      else if (D = 0) and (Toks[K].Text = ';') then
      begin
        RhsEnd := K - 1;
        Break;
      end;
    end;
    RhsFmt := FormatExprSlice(Toks, RhsStart, RhsEnd, RtnIdx, True);
    AppendUsage(State.Routines[RtnIdx].Assigns,
      FmtVar + ' ' + Toks[Q].Text + ' ' + RhsFmt, FileIdx, IdLine);
    I := RhsStart;
    Continue;
  end
  else
  begin
    { Parameterless call if Chain matches a known routine/forward and is standalone }
    AppendUsage(State.Routines[RtnIdx].Vars, FmtVar, FileIdx, IdLine, 'read');
    I := Q;
    Continue;
  end;
end;

Inc(I);


end;
end;

procedure ParseCompoundBlock(RtnIdx, FileIdx: Integer; const Toks: TRawTokenArray;
var Idx: Integer; ParentBlockIdx: Integer; var Ctx: TParseContext);
var
Count, BeginLine, BeginCol, SubBlk, HdrStart, HdrEnd, StmtStart, Depth: Integer;
Low, HdrLabel: string;
begin
Count := Length(Toks);
if (Idx >= Count) or (Toks[Idx].Lower <> 'begin') then
Exit;

BeginLine := Toks[Idx].Line;
BeginCol := Toks[Idx].Col;
Inc(Idx); { skip 'begin' }

while Idx < Count do
begin
if Toks[Idx].Kind = tkLexError then
begin
AddDiagnostic(FileIdx, Toks[Idx].Line, Toks[Idx].Col, EXIT_BIT_SYNTAX, Toks[Idx].Text);
Inc(Idx);
Continue;
end;
if Toks[Idx].Kind = tkDirective then
begin
HandleCompilerDirective(FileIdx, Toks[Idx], Ctx);
Inc(Idx);
Continue;
end;

Low := Toks[Idx].Lower;

if Low = 'end' then
begin
  SetLocation(LastGoodStmt, 'end', FileIdx, Toks[Idx].Line, Toks[Idx].Col);
  CloseLogicBlock(ParentBlockIdx, FileIdx, Toks[Idx].Line);
  Inc(Idx);
  if (Idx < Count) and (Toks[Idx].Text = ';') then
    Inc(Idx);
  Exit;
end;

if Toks[Idx].Text = ';' then
begin
  SetLocation(LastGoodStmt, 'statement', FileIdx, Toks[Idx].Line, Toks[Idx].Col);
  Inc(Idx);
  Continue;
end;

{ Nested begin..end }
if Low = 'begin' then
begin
  SubBlk := AddLogicBlock(bkBegin, 'begin..end', RtnIdx, ParentBlockIdx,
    FileIdx, Toks[Idx].Line, FileIdx, Toks[Idx].Line);
  ParseCompoundBlock(RtnIdx, FileIdx, Toks, Idx, SubBlk, Ctx);
  Continue;
end;

{ if <cond> then ... [else ...] }
if Low = 'if' then
begin
  HdrStart := Idx;
  Inc(Idx);
  Depth := 0;
  while Idx < Count do
  begin
    if (Toks[Idx].Text = '(') or (Toks[Idx].Text = '[') then
      Inc(Depth)
    else if (Toks[Idx].Text = ')') or (Toks[Idx].Text = ']') then
      Dec(Depth)
    else if (Depth = 0) and (Toks[Idx].Lower = 'then') then
      Break;
    Inc(Idx);
  end;
  HdrEnd := Idx - 1;
  if HdrStart + 1 <= HdrEnd then
  begin
    HdrLabel := 'if ' + FormatExprSlice(Toks, HdrStart + 1, HdrEnd, -1, False);
    AnalyzeStmtTokens(RtnIdx, FileIdx, Toks, HdrStart + 1, HdrEnd);
  end
  else
    HdrLabel := 'if';

  SubBlk := AddLogicBlock(bkIf, HdrLabel, RtnIdx, ParentBlockIdx,
    FileIdx, Toks[HdrStart].Line, FileIdx, Toks[HdrStart].Line);
  if (Idx < Count) and (Toks[Idx].Lower = 'then') then
    Inc(Idx);

  if (Idx < Count) and (Toks[Idx].Lower = 'begin') then
  begin
    ParseCompoundBlock(RtnIdx, FileIdx, Toks, Idx, SubBlk, Ctx);
  end
  else
  begin
    StmtStart := Idx;
    Depth := 0;
    while Idx < Count do
    begin
      if Toks[Idx].Kind = tkDirective then
      begin
        HandleCompilerDirective(FileIdx, Toks[Idx], Ctx);
        Inc(Idx);
        Continue;
      end;
      if (Toks[Idx].Text = '(') or (Toks[Idx].Text = '[') then
        Inc(Depth)
      else if (Toks[Idx].Text = ')') or (Toks[Idx].Text = ']') then
        Dec(Depth)
      else if (Depth = 0) and ((Toks[Idx].Text = ';') or (Toks[Idx].Lower = 'else') or (Toks[Idx].Lower = 'end')) then
        Break;
      Inc(Idx);
    end;
    if StmtStart <= Idx - 1 then
    begin
      AnalyzeStmtTokens(RtnIdx, FileIdx, Toks, StmtStart, Idx - 1);
      CloseLogicBlock(SubBlk, FileIdx, Toks[Idx - 1].Line);
    end;
    if (Idx < Count) and (Toks[Idx].Text = ';') then
      Inc(Idx);
  end;

  if (Idx < Count) and (Toks[Idx].Lower = 'else') then
  begin
    SubBlk := AddLogicBlock(bkElse, 'else', RtnIdx, ParentBlockIdx,
      FileIdx, Toks[Idx].Line, FileIdx, Toks[Idx].Line);
    Inc(Idx);
    if (Idx < Count) and (Toks[Idx].Lower = 'begin') then
      ParseCompoundBlock(RtnIdx, FileIdx, Toks, Idx, SubBlk, Ctx);
  end;
  Continue;
end;

{ for / while / with <hdr> do ... }
if (Low = 'for') or (Low = 'while') or (Low = 'with') then
begin
  HdrStart := Idx;
  Inc(Idx);
  Depth := 0;
  while Idx < Count do
  begin
    if (Toks[Idx].Text = '(') or (Toks[Idx].Text = '[') then
      Inc(Depth)
    else if (Toks[Idx].Text = ')') or (Toks[Idx].Text = ']') then
      Dec(Depth)
    else if (Depth = 0) and (Toks[Idx].Lower = 'do') then
      Break;
    Inc(Idx);
  end;
  HdrEnd := Idx - 1;
  if HdrStart + 1 <= HdrEnd then
  begin
    HdrLabel := Low + ' ' + FormatExprSlice(Toks, HdrStart + 1, HdrEnd, -1, False);
    AnalyzeStmtTokens(RtnIdx, FileIdx, Toks, HdrStart + 1, HdrEnd);
  end
  else
    HdrLabel := Low;

  if Low = 'for' then
    SubBlk := AddLogicBlock(bkFor, HdrLabel, RtnIdx, ParentBlockIdx,
      FileIdx, Toks[HdrStart].Line, FileIdx, Toks[HdrStart].Line)
  else if Low = 'while' then
    SubBlk := AddLogicBlock(bkWhile, HdrLabel, RtnIdx, ParentBlockIdx,
      FileIdx, Toks[HdrStart].Line, FileIdx, Toks[HdrStart].Line)
  else
    SubBlk := AddLogicBlock(bkWith, HdrLabel, RtnIdx, ParentBlockIdx,
      FileIdx, Toks[HdrStart].Line, FileIdx, Toks[HdrStart].Line);

  if (Idx < Count) and (Toks[Idx].Lower = 'do') then
    Inc(Idx);
  if (Idx < Count) and (Toks[Idx].Lower = 'begin') then
    ParseCompoundBlock(RtnIdx, FileIdx, Toks, Idx, SubBlk, Ctx);
  Continue;
end;

{ repeat ... until <cond>; }
if Low = 'repeat' then
begin
  SubBlk := AddLogicBlock(bkRepeat, 'repeat..until', RtnIdx, ParentBlockIdx,
    FileIdx, Toks[Idx].Line, FileIdx, Toks[Idx].Line);
  Inc(Idx);
  while (Idx < Count) and (Toks[Idx].Lower <> 'until') do
  begin
    if Toks[Idx].Kind = tkDirective then
    begin
      HandleCompilerDirective(FileIdx, Toks[Idx], Ctx);
      Inc(Idx);
      Continue;
    end;
    if Toks[Idx].Lower = 'begin' then
    begin
      HdrStart := AddLogicBlock(bkBegin, 'begin..end', RtnIdx, SubBlk,
        FileIdx, Toks[Idx].Line, FileIdx, Toks[Idx].Line);
      ParseCompoundBlock(RtnIdx, FileIdx, Toks, Idx, HdrStart, Ctx);
      Continue;
    end;
    StmtStart := Idx;
    while (Idx < Count) and (Toks[Idx].Text <> ';') and (Toks[Idx].Lower <> 'until') do
      Inc(Idx);
    if StmtStart <= Idx - 1 then
      AnalyzeStmtTokens(RtnIdx, FileIdx, Toks, StmtStart, Idx - 1);
    if (Idx < Count) and (Toks[Idx].Text = ';') then
      Inc(Idx)
    else if Idx = StmtStart then
      Inc(Idx);
  end;
  if (Idx < Count) and (Toks[Idx].Lower = 'until') then
  begin
    HdrStart := Idx + 1;
    while (Idx < Count) and (Toks[Idx].Text <> ';') and (Toks[Idx].Lower <> 'end') do
      Inc(Idx);
    if HdrStart <= Idx - 1 then
      AnalyzeStmtTokens(RtnIdx, FileIdx, Toks, HdrStart, Idx - 1);
    if Idx < Count then
      CloseLogicBlock(SubBlk, FileIdx, Toks[Idx].Line)
    else
      CloseLogicBlock(SubBlk, FileIdx, Length(State.Files[FileIdx].Lines));
    if (Idx < Count) and (Toks[Idx].Text = ';') then
      Inc(Idx);
  end;
  Continue;
end;

{ try ... except/finally ... end; }
if Low = 'try' then
begin
  SubBlk := AddLogicBlock(bkTry, 'try..end', RtnIdx, ParentBlockIdx,
    FileIdx, Toks[Idx].Line, FileIdx, Toks[Idx].Line);
  Inc(Idx);
  while (Idx < Count) and (Toks[Idx].Lower <> 'end') do
  begin
    if Toks[Idx].Kind = tkDirective then
    begin
      HandleCompilerDirective(FileIdx, Toks[Idx], Ctx);
      Inc(Idx);
      Continue;
    end;
    if (Toks[Idx].Lower = 'except') or (Toks[Idx].Lower = 'finally') then
    begin
      if Toks[Idx].Lower = 'except' then
        HdrStart := AddLogicBlock(bkExcept, 'except', RtnIdx, SubBlk,
          FileIdx, Toks[Idx].Line, FileIdx, Toks[Idx].Line)
      else
        HdrStart := AddLogicBlock(bkFinally, 'finally', RtnIdx, SubBlk,
          FileIdx, Toks[Idx].Line, FileIdx, Toks[Idx].Line);
      Inc(Idx);
      while (Idx < Count) and (Toks[Idx].Lower <> 'end') do
      begin
        if Toks[Idx].Lower = 'begin' then
        begin
          StmtStart := AddLogicBlock(bkBegin, 'begin..end', RtnIdx, HdrStart,
            FileIdx, Toks[Idx].Line, FileIdx, Toks[Idx].Line);
          ParseCompoundBlock(RtnIdx, FileIdx, Toks, Idx, StmtStart, Ctx);
          Continue;
        end;
        StmtStart := Idx;
        while (Idx < Count) and (Toks[Idx].Text <> ';') and (Toks[Idx].Lower <> 'end') do
          Inc(Idx);
        if StmtStart <= Idx - 1 then
          AnalyzeStmtTokens(RtnIdx, FileIdx, Toks, StmtStart, Idx - 1);
        if (Idx < Count) and (Toks[Idx].Text = ';') then
          Inc(Idx)
        else if Idx = StmtStart then
          Inc(Idx);
      end;
      if Idx < Count then
        CloseLogicBlock(HdrStart, FileIdx, Toks[Idx].Line);
      Continue;
    end;
    if Toks[Idx].Lower = 'begin' then
    begin
      StmtStart := AddLogicBlock(bkBegin, 'begin..end', RtnIdx, SubBlk,
        FileIdx, Toks[Idx].Line, FileIdx, Toks[Idx].Line);
      ParseCompoundBlock(RtnIdx, FileIdx, Toks, Idx, StmtStart, Ctx);
      Continue;
    end;
    StmtStart := Idx;
    while (Idx < Count) and (Toks[Idx].Text <> ';') and
          (Toks[Idx].Lower <> 'except') and (Toks[Idx].Lower <> 'finally') and
          (Toks[Idx].Lower <> 'end') do
      Inc(Idx);
    if StmtStart <= Idx - 1 then
      AnalyzeStmtTokens(RtnIdx, FileIdx, Toks, StmtStart, Idx - 1);
    if (Idx < Count) and (Toks[Idx].Text = ';') then
      Inc(Idx)
    else if Idx = StmtStart then
      Inc(Idx);
  end;
  if (Idx < Count) and (Toks[Idx].Lower = 'end') then
  begin
    CloseLogicBlock(SubBlk, FileIdx, Toks[Idx].Line);
    Inc(Idx);
    if (Idx < Count) and (Toks[Idx].Text = ';') then
      Inc(Idx);
  end;
  Continue;
end;

{ case <expr> of ... end; }
if Low = 'case' then
begin
  HdrStart := Idx;
  Inc(Idx);
  while (Idx < Count) and (Toks[Idx].Lower <> 'of') do
    Inc(Idx);
  if HdrStart + 1 <= Idx - 1 then
  begin
    HdrLabel := 'case ' + FormatExprSlice(Toks, HdrStart + 1, Idx - 1, -1, False);
    AnalyzeStmtTokens(RtnIdx, FileIdx, Toks, HdrStart + 1, Idx - 1);
  end
  else
    HdrLabel := 'case';
  SubBlk := AddLogicBlock(bkCase, HdrLabel, RtnIdx, ParentBlockIdx,
    FileIdx, Toks[HdrStart].Line, FileIdx, Toks[HdrStart].Line);
  if (Idx < Count) and (Toks[Idx].Lower = 'of') then
    Inc(Idx);
  while (Idx < Count) and (Toks[Idx].Lower <> 'end') do
  begin
    if Toks[Idx].Lower = 'begin' then
    begin
      StmtStart := AddLogicBlock(bkBegin, 'begin..end', RtnIdx, SubBlk,
        FileIdx, Toks[Idx].Line, FileIdx, Toks[Idx].Line);
      ParseCompoundBlock(RtnIdx, FileIdx, Toks, Idx, StmtStart, Ctx);
      Continue;
    end;
    StmtStart := Idx;
    while (Idx < Count) and (Toks[Idx].Text <> ';') and (Toks[Idx].Lower <> 'end') do
    begin
      if Toks[Idx].Kind = tkDirective then
      begin
        HandleCompilerDirective(FileIdx, Toks[Idx], Ctx);
        Inc(Idx);
        Continue;
      end;
      Inc(Idx);
    end;
    if StmtStart <= Idx - 1 then
      AnalyzeStmtTokens(RtnIdx, FileIdx, Toks, StmtStart, Idx - 1);
    if (Idx < Count) and (Toks[Idx].Text = ';') then
      Inc(Idx)
    else if Idx = StmtStart then
      Inc(Idx);
  end;
  if (Idx < Count) and (Toks[Idx].Lower = 'end') then
  begin
    CloseLogicBlock(SubBlk, FileIdx, Toks[Idx].Line);
    Inc(Idx);
    if (Idx < Count) and (Toks[Idx].Text = ';') then
      Inc(Idx);
  end;
  Continue;
end;

{ asm ... end; }
if Low = 'asm' then
begin
  SubBlk := AddLogicBlock(bkAsm, 'asm..end', RtnIdx, ParentBlockIdx,
    FileIdx, Toks[Idx].Line, FileIdx, Toks[Idx].Line);
  Inc(Idx);
  while (Idx < Count) and (Toks[Idx].Lower <> 'end') do
    Inc(Idx);
  if (Idx < Count) and (Toks[Idx].Lower = 'end') then
  begin
    CloseLogicBlock(SubBlk, FileIdx, Toks[Idx].Line);
    Inc(Idx);
    if (Idx < Count) and (Toks[Idx].Text = ';') then
      Inc(Idx);
  end;
  Continue;
end;

{ Simple statement up to ';', 'end', or 'else' }
StmtStart := Idx;
Depth := 0;
while Idx < Count do
begin
  if Toks[Idx].Kind = tkDirective then
  begin
    HandleCompilerDirective(FileIdx, Toks[Idx], Ctx);
    Inc(Idx);
    Continue;
  end;
  if (Toks[Idx].Text = '(') or (Toks[Idx].Text = '[') then
    Inc(Depth)
  else if (Toks[Idx].Text = ')') or (Toks[Idx].Text = ']') then
    Dec(Depth)
  else if (Depth = 0) and
          ((Toks[Idx].Text = ';') or (Toks[Idx].Lower = 'end') or
           (Toks[Idx].Lower = 'else') or (Toks[Idx].Lower = 'until')) then
    Break;
  Inc(Idx);
end;
if StmtStart <= Idx - 1 then
  AnalyzeStmtTokens(RtnIdx, FileIdx, Toks, StmtStart, Idx - 1);
if (Idx < Count) and (Toks[Idx].Text = ';') then
begin
  SetLocation(LastGoodStmt, 'statement', FileIdx, Toks[Idx].Line, Toks[Idx].Col);
  Inc(Idx);
end
else if Idx = StmtStart then
  Inc(Idx);


end;

AddDiagnostic(FileIdx, MaxIntVal(1, Length(State.Files[FileIdx].Lines)), 1,
EXIT_BIT_STRUCTURAL,
'Unclosed "begin" opened at "' + FileDisplay(FileIdx) + '": Line ' +
IntToStr(BeginLine) + ', Col ' + IntToStr(BeginCol) + ' before EOF');
end;

procedure ParseRoutineImplementation(FileIdx: Integer; var Idx: Integer;
ParentBlockIdx: Integer; var Ctx: TParseContext);
var
Toks: TRawTokenArray;
Count, StartLn, StartCol, RtnIdx, RootBlkIdx, PrevRtn, PrevBlk: Integer;
RKind, RName, RRet, RSig: string;
RParams: TUsageItemArray;
IsExt, IsFwd: Boolean;
Rtn: TRoutineInfo;
begin
Toks := State.Files[FileIdx].Tokens;
Count := Length(Toks);
StartLn := Toks[Idx].Line;
StartCol := Toks[Idx].Col;

ParseRoutineHeadAndDirectives(Toks, Idx, FileIdx, RKind, RName, RRet, RSig,
RParams, IsExt, IsFwd);

if Ctx.InInterface or IsExt or IsFwd then
begin
RecordForwardDecl(RName, RKind, RSig, FileIdx, StartLn,
(Ctx.InInterface or IsFwd) and (not IsExt));
Exit;
end;

SetLocation(LastGoodBlock, RKind + ' ' + RName, FileIdx, StartLn, StartCol);
LinkForwardImplementation(RName, FileIdx, StartLn);

RtnIdx := Length(State.Routines);
Rtn.Name := RName;
Rtn.Kind := RKind;
Rtn.ReturnType := RRet;
Rtn.FileIdx := FileIdx;
Rtn.StartLine := StartLn;
Rtn.EndFileIdx := FileIdx;
Rtn.EndLine := StartLn;
Rtn.Includes := nil;
Rtn.Params := RParams;
Rtn.Locals := nil;
Rtn.Assigns := nil;
Rtn.Vars := nil;
Rtn.Calls := nil;

RootBlkIdx := AddLogicBlock(bkRoutine, RSig, RtnIdx, ParentBlockIdx,
FileIdx, StartLn, FileIdx, StartLn);
Rtn.RootBlockIdx := RootBlkIdx;

SetLength(State.Routines, RtnIdx + 1);
State.Routines[RtnIdx] := Rtn;

PrevRtn := Ctx.ActiveRoutineIdx;
PrevBlk := Ctx.ActiveBlockIdx;
Ctx.ActiveRoutineIdx := RtnIdx;
Ctx.ActiveBlockIdx := RootBlkIdx;

{ Local declarations (type, const, var, nested routines) before routine 'begin' }
while Idx < Count do
begin
if Toks[Idx].Kind = tkDirective then
begin
HandleCompilerDirective(FileIdx, Toks[Idx], Ctx);
Inc(Idx);
Continue;
end;
if Toks[Idx].Lower = 'type' then
begin
ParseTypeSection(Toks, Idx, FileIdx, Ctx);
Continue;
end;
if (Toks[Idx].Lower = 'const') or (Toks[Idx].Lower = 'resourcestring') then
begin
ParseVarOrConstSection(Toks, Idx, FileIdx, True, RtnIdx, Ctx);
Continue;
end;
if (Toks[Idx].Lower = 'var') or (Toks[Idx].Lower = 'threadvar') then
begin
ParseVarOrConstSection(Toks, Idx, FileIdx, False, RtnIdx, Ctx);
Continue;
end;
if IsRoutineStarter(Toks[Idx].Lower) then
begin
ParseRoutineImplementation(FileIdx, Idx, RootBlkIdx, Ctx);
Continue;
end;
if Toks[Idx].Lower = 'begin' then
Break;
Inc(Idx);
end;

if (Idx < Count) and (Toks[Idx].Lower = 'begin') then
begin
ParseCompoundBlock(RtnIdx, FileIdx, Toks, Idx, RootBlkIdx, Ctx);
State.Routines[RtnIdx].EndFileIdx := State.LogicBlocks[RootBlkIdx].EndFileIdx;
State.Routines[RtnIdx].EndLine := State.LogicBlocks[RootBlkIdx].EndLine;
end;

Ctx.ActiveRoutineIdx := PrevRtn;
Ctx.ActiveBlockIdx := PrevBlk;
end;

procedure ParseFileTokens(FileIdx: Integer; var Ctx: TParseContext);
var
Toks: TRawTokenArray;
Count, BaseBracketDepth, I, MainBlk: Integer;
Low, Expected: string;
BI: TBracketItem;
SecBlk, UStart: Integer;
PreambleDone: Boolean;

{ Emit a HEAD container for lines before the first modeled top-level construct. }
procedure EnsurePreamble(UpToLine: Integer);
begin
  if PreambleDone then Exit;
  if UpToLine > 1 then
    AddLogicBlock(bkUnitSection, 'unit/program preamble', -1, -1, FileIdx,
      1, FileIdx, UpToLine - 1);
  PreambleDone := True;
end;

begin
Toks := State.Files[FileIdx].Tokens;
Count := Length(Toks);
PreambleDone := False;

{ Determine the preamble span up-front so containers are created in source order. }
if Count > 0 then
begin
  for I := 0 to Count - 1 do
  begin
    if (Toks[I].Kind = tkLexError) or (Toks[I].Kind = tkDirective) then Continue;
    Low := Toks[I].Lower;
    if (Low = 'interface') or (Low = 'implementation') or (Low = 'uses') or
       (Low = 'type') or (Low = 'const') or (Low = 'resourcestring') or
       (Low = 'var') or (Low = 'threadvar') or (Low = 'begin') or
       (Low = 'initialization') or (Low = 'finalization') or
       IsRoutineStarter(Low) then
    begin
      EnsurePreamble(Toks[I].Line);
      Break;
    end;
  end;
  if not PreambleDone then
    EnsurePreamble(Toks[Count - 1].Line + 1);
end;

{ Pass 1: Check balanced (), [] across the file }
BaseBracketDepth := Length(Brackets);
for I := 0 to Count - 1 do
begin
if Toks[I].Kind = tkLexError then
begin
AddDiagnostic(FileIdx, Toks[I].Line, Toks[I].Col, EXIT_BIT_SYNTAX, Toks[I].Text);
Continue;
end;
if (Toks[I].Text = '(') or (Toks[I].Text = '[') then
begin
BI.TokenText := Toks[I].Text;
BI.FileIdx := FileIdx;
BI.Line := Toks[I].Line;
BI.Col := Toks[I].Col;
BI.Snippet := GetLineSnippet(FileIdx, Toks[I].Line);
SetLength(Brackets, Length(Brackets) + 1);
Brackets[High(Brackets)] := BI;
end
else if (Toks[I].Text = ')') or (Toks[I].Text = ']') then
begin
if Toks[I].Text = ')' then
Expected := '('
else
Expected := '[';
if Length(Brackets) <= BaseBracketDepth then
AddDiagnostic(FileIdx, Toks[I].Line, Toks[I].Col, EXIT_BIT_STRUCTURAL,
'Unexpected "' + Toks[I].Text + '" with no matching "' + Expected + '"')
else
begin
BI := Brackets[High(Brackets)];
SetLength(Brackets, Length(Brackets) - 1);
if BI.TokenText <> Expected then
AddDiagnostic(FileIdx, Toks[I].Line, Toks[I].Col, EXIT_BIT_STRUCTURAL,
'Mismatched "' + Toks[I].Text + '" closing "' + BI.TokenText +
'" opened at "' + FileDisplay(BI.FileIdx) + '": Line ' +
IntToStr(BI.Line) + ', Col ' + IntToStr(BI.Col),
'Opened at:', BI.Snippet);
end;
end;
end;

while Length(Brackets) > BaseBracketDepth do
begin
BI := Brackets[High(Brackets)];
SetLength(Brackets, Length(Brackets) - 1);
AddDiagnostic(FileIdx, MaxIntVal(1, Length(State.Files[FileIdx].Lines)), 1,
EXIT_BIT_STRUCTURAL,
'Unclosed "' + BI.TokenText + '" opened at "' + FileDisplay(BI.FileIdx) +
'": Line ' + IntToStr(BI.Line) + ', Col ' + IntToStr(BI.Col) + ' before EOF',
'Opened at:', BI.Snippet);
end;

{ Pass 2: Top-level declarations, sections, and routines }
I := 0;
while I < Count do
begin
if Toks[I].Kind = tkLexError then
begin
Inc(I);
Continue;
end;
if Toks[I].Kind = tkDirective then
begin
HandleCompilerDirective(FileIdx, Toks[I], Ctx);
Inc(I);
Continue;
end;

  SkipAttributeGroups(Toks, I, Count);
if I >= Count then Break;

Low := Toks[I].Lower;

if Low = 'interface' then
begin
  EnsurePreamble(Toks[I].Line);
  AddLogicBlock(bkDeclSection, 'interface section marker', -1, -1,
    FileIdx, Toks[I].Line, FileIdx, Toks[I].Line);
  Ctx.InInterface := True;
  Inc(I);
  Continue;
end;

if Low = 'implementation' then
begin
  EnsurePreamble(Toks[I].Line);
  AddLogicBlock(bkDeclSection, 'implementation section marker', -1, -1,
    FileIdx, Toks[I].Line, FileIdx, Toks[I].Line);
  Ctx.InInterface := False;
  Inc(I);
  Continue;
end;

if Low = 'uses' then
begin
  EnsurePreamble(Toks[I].Line);
  UStart := I;
  while (I < Count) and (Toks[I].Text <> ';') do Inc(I);
  ResolveUsesNames(Toks, UStart + 1, I - 1, FileIdx, Ctx);
  if I < Count then Inc(I);
  AddLogicBlock(bkUnitSection, 'uses clause', -1, -1, FileIdx,
    Toks[UStart].Line, FileIdx, Toks[MaxIntVal(UStart, I - 1)].Line);
  Continue;
end;

if Low = 'type' then
begin
  EnsurePreamble(Toks[I].Line);
  SecBlk := AddLogicBlock(bkDeclSection, 'type declaration section', -1, -1,
    FileIdx, Toks[I].Line, FileIdx, Toks[I].Line);
  ParseTypeSection(Toks, I, FileIdx, Ctx);
  if I > 0 then CloseLogicBlock(SecBlk, FileIdx, Toks[I - 1].Line);
  Continue;
end;

if (Low = 'const') or (Low = 'resourcestring') then
begin
  EnsurePreamble(Toks[I].Line);
  SecBlk := AddLogicBlock(bkDeclSection, Low + ' declaration section', -1, -1,
    FileIdx, Toks[I].Line, FileIdx, Toks[I].Line);
  ParseVarOrConstSection(Toks, I, FileIdx, True, Ctx.ActiveRoutineIdx, Ctx);
  if I > 0 then CloseLogicBlock(SecBlk, FileIdx, Toks[I - 1].Line);
  Continue;
end;

if (Low = 'var') or (Low = 'threadvar') then
begin
  EnsurePreamble(Toks[I].Line);
  SecBlk := AddLogicBlock(bkDeclSection, Low + ' declaration section', -1, -1,
    FileIdx, Toks[I].Line, FileIdx, Toks[I].Line);
  ParseVarOrConstSection(Toks, I, FileIdx, False, Ctx.ActiveRoutineIdx, Ctx);
  if I > 0 then CloseLogicBlock(SecBlk, FileIdx, Toks[I - 1].Line);
  Continue;
end;

if IsRoutineStarter(Low) then
begin
  EnsurePreamble(Toks[I].Line);
  ParseRoutineImplementation(FileIdx, I, Ctx.ActiveBlockIdx, Ctx);
  Continue;
end;

if (Low = 'begin') or (Low = 'initialization') or (Low = 'finalization') then
begin
  EnsurePreamble(Toks[I].Line);
  if Low <> 'begin' then
  begin
    MainBlk := AddLogicBlock(bkInitBlock, Low + '..end', -1, -1,
      FileIdx, Toks[I].Line, FileIdx, Toks[I].Line);
    Inc(I);
    while (I < Count) and (Toks[I].Lower <> 'end') and (Toks[I].Lower <> 'finalization') do
    begin
      if Toks[I].Kind = tkDirective then
        HandleCompilerDirective(FileIdx, Toks[I], Ctx);
      Inc(I);
    end;
    if (I < Count) and (Toks[I].Lower = 'finalization') then
    begin
      if I > 0 then
        CloseLogicBlock(MainBlk, FileIdx, Toks[I - 1].Line);
    end
    else if (I < Count) and (Toks[I].Lower = 'end') then
    begin
      CloseLogicBlock(MainBlk, FileIdx, Toks[I].Line);
      Inc(I);
    end
    else if Count > 0 then
      CloseLogicBlock(MainBlk, FileIdx, Toks[Count - 1].Line);
  end
  else
  begin
    MainBlk := AddLogicBlock(bkBegin, 'main begin..end.', -1, -1,
      FileIdx, Toks[I].Line, FileIdx, Toks[I].Line);
    ParseCompoundBlock(-1, FileIdx, Toks, I, MainBlk, Ctx);
  end;
  Continue;
end;

Inc(I);


end;
end;

{ ============================================================================
Normalized Pascal Token Search (--search), Callers (--callers), Scoped Blocks
============================================================================ }

function ExtractSearchableTokens(const Raw: TRawTokenArray): TRawTokenArray;
var
I, N: Integer;
begin
Result := nil;
SetLength(Result, Length(Raw));
N := 0;
for I := 0 to High(Raw) do
if Raw[I].Kind in [tkIdent, tkSymbol, tkString, tkNumber] then
begin
Result[N] := Raw[I];
Inc(N);
end;
SetLength(Result, N);
end;

function TokenMatchesPattern(const FileTok, PatTok: TRawToken): Boolean;
begin
if FileTok.Kind <> PatTok.Kind then
Exit(False);
if FileTok.Kind = tkIdent then
Result := FileTok.Lower = PatTok.Lower
else
Result := FileTok.Text = PatTok.Text;
end;

function RunPascalTokenSearch(const APattern: string): TSearchHitArray;
var
PatNorm, FToks: TRawTokenArray;
PCount, FIdx, MPos, K, EndIdx: Integer;
Matched: Boolean;
Hit: TSearchHit;
begin
Result := nil;
if Trim(APattern) = '' then
Exit;

PatNorm := ExtractSearchableTokens(LexPascalSource(APattern));
PCount := Length(PatNorm);
if PCount = 0 then
Exit;

for FIdx := 0 to High(State.Files) do
begin
FToks := ExtractSearchableTokens(State.Files[FIdx].Tokens);
if Length(FToks) < PCount then
Continue;

MPos := 0;
while MPos <= Length(FToks) - PCount do
begin
  Matched := True;
  for K := 0 to PCount - 1 do
    if not TokenMatchesPattern(FToks[MPos + K], PatNorm[K]) then
    begin
      Matched := False;
      Break;
    end;

  if Matched then
  begin
    EndIdx := MPos + PCount - 1;
    Hit.FileIdx := FIdx;
    Hit.StartLine := FToks[MPos].Line;
    Hit.EndLine := FToks[EndIdx].Line;
    Hit.Col := FToks[MPos].Col;
    Hit.Snippet := GetLineSnippet(FIdx, FToks[MPos].Line);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Hit;
    MPos := EndIdx + 1;
  end
  else
    Inc(MPos);
end;


end;
end;

function FindCallersOf(const ASymbol: string): TCallerHitArray;
var
RIdx, CIdx, SIdx, TailStart, SymLen, CallLen, B, FIdx, H: Integer;
LowSym, LowCall, TailSub: string;
SHits: TSearchHitArray;
IsMatch: Boolean;
Hit: TCallerHit;
begin
Result := nil;
if Trim(ASymbol) = '' then
Exit;
LowSym := LowerCase(Trim(ASymbol));
SymLen := Length(LowSym);

for RIdx := 0 to High(State.Routines) do
begin
for CIdx := 0 to High(State.Routines[RIdx].Calls) do
begin
LowCall := LowerCase(State.Routines[RIdx].Calls[CIdx].Name);
CallLen := Length(LowCall);
IsMatch := (Pos(' ' + LowSym + ':', LowCall) > 0) or
(Pos('.' + LowSym + ':', LowCall) > 0);
if (not IsMatch) and (CallLen >= SymLen + 1) then
begin
TailStart := CallLen - SymLen;
TailSub := Copy(LowCall, TailStart, SymLen + 1);
if (TailSub = ' ' + LowSym) or (TailSub = '.' + LowSym) then
IsMatch := True;
end;

  if IsMatch then
  begin
    for SIdx := 0 to High(State.Routines[RIdx].Calls[CIdx].Sites) do
    begin
      Hit.CallerRoutine := State.Routines[RIdx].Name;
      Hit.FileIdx := State.Routines[RIdx].Calls[CIdx].Sites[SIdx].FileIdx;
      Hit.Line := State.Routines[RIdx].Calls[CIdx].Sites[SIdx].Line;
      Hit.CallText := State.Routines[RIdx].Calls[CIdx].Name;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Hit;
    end;
  end;
end;
  { Calls from top-level entry blocks (program main begin..end., initialization)
    are parsed with RtnIdx=-1 and are not recorded in any routine's Calls list;
    include them so -callers reports the complete call graph. Token search is
    used so comments and string literals cannot create false caller sites. }
  SHits := RunPascalTokenSearch(Trim(ASymbol));
  for B := 0 to High(State.LogicBlocks) do
    if ((State.LogicBlocks[B].Kind = bkBegin) or
        (State.LogicBlocks[B].Kind = bkInitBlock)) and
       (State.LogicBlocks[B].OwnerRoutineIdx < 0) and
       (State.LogicBlocks[B].ParentIdx < 0) then
    begin
      FIdx := State.LogicBlocks[B].FileIdx;
      for H := 0 to High(SHits) do
        if (SHits[H].FileIdx = FIdx) and
           (SHits[H].StartLine >= State.LogicBlocks[B].StartLine) and
           (SHits[H].EndLine <= State.LogicBlocks[B].EndLine) then
        begin
          Hit.CallerRoutine := '<main>';
          Hit.FileIdx := FIdx;
          Hit.Line := SHits[H].StartLine;
          Hit.CallText := ASymbol;
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := Hit;
        end;
    end;

end;
end;
function RoutineSimpleName(const AName: string): string;
var P: Integer;
begin
  Result := AName;
  P := LastDelimiter('.', Result);
  if P > 0 then
    Result := Copy(Result, P + 1, MaxInt);
end;

function ContainsIdentCI(const Text, Ident: string): Boolean;
var
  P, L, N: Integer;
  ChB, ChA: Char;
begin
  Result := False;
  L := Length(Ident);
  N := Length(Text);
  if (L = 0) or (N < L) then
    Exit;
  P := 1;
  while P <= N - L + 1 do
  begin
    if CompareText(Copy(Text, P, L), Ident) = 0 then
    begin
      if P > 1 then ChB := Text[P - 1] else ChB := #0;
      if P + L <= N then ChA := Text[P + L] else ChA := #0;
      if (not IsAlnumOrUnderscore(ChB)) and (not IsAlnumOrUnderscore(ChA)) then
      begin
        Result := True;
        Exit;
      end;
    end;
    Inc(P);
  end;
end;

function UsageRefersToRoutine(const UsageName, RoutineName: string): Boolean;
var
  S, Base, USimple, RSimple: string;
  P: Integer;
  IsCall: Boolean;
begin
  Result := False;
  RSimple := RoutineSimpleName(RoutineName);
  IsCall := (Length(UsageName) >= 5) and (CompareText(Copy(UsageName, 1, 5), 'call ') = 0);
  if IsCall then
  begin
    S := Trim(Copy(UsageName, 6, MaxInt));
    P := Pos(': ', S);
    if P > 0 then
      S := Trim(Copy(S, 1, P - 1));
    Base := S;
  end
  else
  begin
    Base := UsageName;
    P := Pos(':', Base);
    if P > 0 then
      Base := Copy(Base, 1, P - 1);
    Base := Trim(Base);
  end;
  if Base = '' then
    Exit;
  USimple := RoutineSimpleName(Base);
  if SameText(Base, RoutineName) or SameText(Base, RSimple) or
     SameText(USimple, RSimple) then
    Result := True;
end;

procedure ComputeRoutineReachability(out Reachable: TBoolArray;
  out HasEntryRoots: Boolean; out EntrySeeded: Integer);
var
  I, B, L, R, U, Changed: Integer;
  N, FIdx, SLine, ELine: Integer;
  LineText: string;
begin
  N := Length(State.Routines);
  SetLength(Reachable, N);
  for I := 0 to N - 1 do
    Reachable[I] := False;
  HasEntryRoots := False;
  EntrySeeded := 0;

  { Seed from top-level entry blocks: program main begin..end., initialization, finalization }
  for B := 0 to High(State.LogicBlocks) do
    if ((State.LogicBlocks[B].Kind = bkBegin) or
        (State.LogicBlocks[B].Kind = bkInitBlock)) and
       (State.LogicBlocks[B].OwnerRoutineIdx < 0) and
       (State.LogicBlocks[B].ParentIdx < 0) then
    begin
      HasEntryRoots := True;
      FIdx := State.LogicBlocks[B].FileIdx;
      SLine := State.LogicBlocks[B].StartLine;
      ELine := State.LogicBlocks[B].EndLine;
      if SLine < 1 then SLine := 1;
      for L := SLine to ELine do
      begin
        LineText := GetLineRaw(FIdx, L);
        if LineText = '' then Continue;
        for R := 0 to N - 1 do
          if (not Reachable[R]) and
             ContainsIdentCI(LineText, RoutineSimpleName(State.Routines[R].Name)) then
          begin
            Reachable[R] := True;
            Inc(EntrySeeded);
          end;
      end;
    end;

  { Seed from published methods and exported routines (entry points) }
  for R := 0 to N - 1 do
  begin
    if Reachable[R] then Continue;
    if (State.Routines[R].Kind = 'published') or
       (State.Routines[R].Kind = 'export') or
       (State.Routines[R].Kind = 'callback') then
    begin
      Reachable[R] := True;
      Inc(EntrySeeded);
      HasEntryRoots := True;
    end;
  end;

  { Seed from event-handler / callback naming patterns (OnClick, OnChange, etc.) }
  for R := 0 to N - 1 do
  begin
    if Reachable[R] then Continue;
    if (Pos('OnClick', State.Routines[R].Name) > 0) or
       (Pos('OnChange', State.Routines[R].Name) > 0) or
       (Pos('OnCreate', State.Routines[R].Name) > 0) or
       (Pos('OnDestroy', State.Routines[R].Name) > 0) or
       (Pos('OnShow', State.Routines[R].Name) > 0) or
       (Pos('OnHide', State.Routines[R].Name) > 0) or
       (Pos('OnClose', State.Routines[R].Name) > 0) or
       (Pos('OnTimer', State.Routines[R].Name) > 0) or
       (Pos('OnPaint', State.Routines[R].Name) > 0) or
       (Pos('OnResize', State.Routines[R].Name) > 0) or
       (Pos('OnKeyDown', State.Routines[R].Name) > 0) or
       (Pos('OnKeyUp', State.Routines[R].Name) > 0) or
       (Pos('OnKeyPress', State.Routines[R].Name) > 0) or
       (Pos('OnMouseDown', State.Routines[R].Name) > 0) or
       (Pos('OnMouseUp', State.Routines[R].Name) > 0) or
       (Pos('OnMouseMove', State.Routines[R].Name) > 0) or
       (Pos('OnDblClick', State.Routines[R].Name) > 0) then
    begin
      Reachable[R] := True;
      Inc(EntrySeeded);
      HasEntryRoots := True;
    end;
  end;


  repeat
    Changed := 0;
    for R := 0 to N - 1 do
      if Reachable[R] then
      begin
        for U := 0 to High(State.Routines[R].Calls) do
          for I := 0 to N - 1 do
            if (not Reachable[I]) and
               UsageRefersToRoutine(State.Routines[R].Calls[U].Name, State.Routines[I].Name) then
            begin
              Reachable[I] := True;
              Inc(Changed);
            end;
        for U := 0 to High(State.Routines[R].Vars) do
          for I := 0 to N - 1 do
            if (not Reachable[I]) and
               UsageRefersToRoutine(State.Routines[R].Vars[U].Name, State.Routines[I].Name) then
            begin
              Reachable[I] := True;
              Inc(Changed);
            end;
        for U := 0 to High(State.Routines[R].Assigns) do
          for I := 0 to N - 1 do
            if (not Reachable[I]) and
               UsageRefersToRoutine(State.Routines[R].Assigns[U].Name, State.Routines[I].Name) then
            begin
              Reachable[I] := True;
              Inc(Changed);
            end;
      end;
  until Changed = 0;
end;



function FindInnermostLogicBlockAt(FileIdx, LineNum: Integer): Integer;
var
I, BestIdx, BestSpan, Span: Integer;
begin
BestIdx := -1;
BestSpan := MaxInt;
for I := 0 to High(State.LogicBlocks) do
if (State.LogicBlocks[I].FileIdx = FileIdx) and
(LineNum >= State.LogicBlocks[I].StartLine) and
(LineNum <= State.LogicBlocks[I].EndLine) then
begin
Span := State.LogicBlocks[I].EndLine - State.LogicBlocks[I].StartLine + 1;
if (Span < BestSpan) or ((Span = BestSpan) and (I > BestIdx)) then
begin
BestSpan := Span;
BestIdx := I;
end;
end;
Result := BestIdx;
end;

function FindScopedBlockMatch(const Query: string): TBlockMatch;
var
Q, TargetPart, Seg: string;
Parts: TStringArray;
P, NextColon, NodeId, I, CandIdx, RIdx, BestBlk: Integer;
Hits: TSearchHitArray;
AllScopeOk: Boolean;

function BlockMatchesScopeSeg(BlkIdx: Integer; const ScopeSeg: string): Boolean;
var
Cur: Integer;
begin
Cur := BlkIdx;
while Cur >= 0 do
begin
if StrContainsCI(State.LogicBlocks[Cur].LabelText, ScopeSeg) then
Exit(True);
if (State.LogicBlocks[Cur].OwnerRoutineIdx >= 0) and
StrContainsCI(State.Routines[State.LogicBlocks[Cur].OwnerRoutineIdx].Name, ScopeSeg) then
Exit(True);
Cur := State.LogicBlocks[Cur].ParentIdx;
end;
Result := False;
end;

begin
Result.Found := False;
Result.BlockIdx := -1;
Result.MatchFileIdx := 0;
Result.MatchLine := 1;
Result.MatchSnippet := '';
Result.FromToken := False;

Q := Trim(Query);
if Q = '' then
Exit;

{ Direct node ID query: "#14" }
if (Q[1] = '#') and (Length(Q) > 1) then
begin
NodeId := StrToIntDef(Copy(Q, 2, MaxInt), -1);
if (NodeId >= 1) and (NodeId <= Length(State.LogicBlocks)) then
begin
Result.Found := True;
Result.BlockIdx := NodeId - 1;
Result.MatchFileIdx := State.LogicBlocks[Result.BlockIdx].FileIdx;
Result.MatchLine := State.LogicBlocks[Result.BlockIdx].StartLine;
Result.MatchSnippet := GetLineSnippet(Result.MatchFileIdx, Result.MatchLine);
end;
Exit;
end;

{ Split scoped segments by single ':' while keeping ':=' intact }
Parts := nil;
P := 1;
while P <= Length(Q) do
begin
NextColon := 0;
for I := P to Length(Q) do
if (Q[I] = ':') and ((I = Length(Q)) or (Q[I + 1] <> '=')) and
((I = 1) or (Q[I - 1] <> ':')) then
begin
NextColon := I;
Break;
end;

if NextColon = 0 then
begin
  Seg := Trim(Copy(Q, P, MaxInt));
  if Seg <> '' then
  begin
    SetLength(Parts, Length(Parts) + 1);
    Parts[High(Parts)] := Seg;
  end;
  Break;
end
else
begin
  Seg := Trim(Copy(Q, P, NextColon - P));
  if Seg <> '' then
  begin
    SetLength(Parts, Length(Parts) + 1);
    Parts[High(Parts)] := Seg;
  end;
  P := NextColon + 1;
end;


end;

if Length(Parts) = 0 then
Exit;
TargetPart := Parts[High(Parts)];

{ 1. Direct routine or logic-block header match }
if Length(Parts) = 1 then
begin
for RIdx := 0 to High(State.Routines) do
if SameText(State.Routines[RIdx].Name, TargetPart) and
(State.Routines[RIdx].RootBlockIdx >= 0) then
begin
Result.Found := True;
Result.BlockIdx := State.Routines[RIdx].RootBlockIdx;
Result.MatchFileIdx := State.Routines[RIdx].FileIdx;
Result.MatchLine := State.Routines[RIdx].StartLine;
Result.MatchSnippet := GetLineSnippet(Result.MatchFileIdx, Result.MatchLine);
Exit;
end;

for I := 0 to High(State.LogicBlocks) do
  if StrContainsCI(State.LogicBlocks[I].LabelText, TargetPart) then
  begin
    Result.Found := True;
    Result.BlockIdx := I;
    Result.MatchFileIdx := State.LogicBlocks[I].FileIdx;
    Result.MatchLine := State.LogicBlocks[I].StartLine;
    Result.MatchSnippet := GetLineSnippet(Result.MatchFileIdx, Result.MatchLine);
    Exit;
  end;


end;

{ 2. Lexical token search for TargetPart constrained by outer scope segments }
Hits := RunPascalTokenSearch(TargetPart);
for I := 0 to High(Hits) do
begin
CandIdx := FindInnermostLogicBlockAt(Hits[I].FileIdx, Hits[I].StartLine);
AllScopeOk := True;
for P := 0 to High(Parts) - 1 do
if (CandIdx < 0) or (not BlockMatchesScopeSeg(CandIdx, Parts[P])) then
begin
AllScopeOk := False;
Break;
end;

if AllScopeOk then
begin
  Result.Found := True;
  Result.FromToken := True;
  Result.MatchFileIdx := Hits[I].FileIdx;
  Result.MatchLine := Hits[I].StartLine;
  Result.MatchSnippet := Hits[I].Snippet;
  if CandIdx >= 0 then
  begin
    { Promote to enclosing routine/block if it fits inside Options.BlockChunkSize }
    BestBlk := CandIdx;
    while (BestBlk >= 0) and (State.LogicBlocks[BestBlk].ParentIdx >= 0) do
    begin
      P := State.LogicBlocks[BestBlk].ParentIdx;
      if (State.LogicBlocks[P].EndLine - State.LogicBlocks[P].StartLine + 1) <= Options.BlockChunkSize then
        BestBlk := P
      else
        Break;
    end;
    Result.BlockIdx := BestBlk;
  end
  else
    Result.BlockIdx := -1;
  Exit;
end;


end;
end;

{ Resolve any target specification (#id, symbol, scope-chain, label text)
  to a valid State.LogicBlocks index, or -1 if not found. }
function ResolveBlockTargetIndex(const Target: string): Integer;
var
  BM: TBlockMatch;
  I: Integer;
  T: string;
begin
  Result := -1;
  T := Trim(Target);
  if T = '' then Exit;
  BM := FindScopedBlockMatch(T);
  if (not BM.Found) and (Copy(T, 1, 1) = '#') and (Length(T) > 1) then
    BM := FindScopedBlockMatch(Copy(T, 2, MaxInt));
  if (not BM.Found) and (Pos(' ', T) > 0) then
    for I := 0 to High(State.LogicBlocks) do
      if SameText(State.LogicBlocks[I].LabelText, T) or
         StrContainsCI(State.LogicBlocks[I].LabelText, T) then
      begin
        BM.Found := True;
        BM.BlockIdx := I;
        Break;
      end;
  if BM.Found and (BM.BlockIdx >= 0) and (BM.BlockIdx < Length(State.LogicBlocks)) then
    Result := BM.BlockIdx;
end;

function CollectChunkProvenance(FileIdx, ChunkStartLn, ChunkEndLn,
OwnerRtnIdx: Integer): TProvenanceEntryArray;
var
Toks: TRawTokenArray;
Seen: TStringArray;
I, J, K, TargetBlk, TargetChunk: Integer;
Ident, LowId: string;
AlreadySeen, FoundLocal: Boolean;

procedure AddProv(const Sym, KindLbl, Det: string; FIdx, Ln: Integer);
var
N: Integer;
begin
N := Length(Result);
SetLength(Result, N + 1);
Result[N].SymbolName := Sym;
Result[N].KindLabel := KindLbl;
Result[N].Detail := Det;
Result[N].FileIdx := FIdx;
Result[N].Line := Ln;
TargetBlk := FindInnermostLogicBlockAt(FIdx, Ln);
if TargetBlk >= 0 then
begin
TargetChunk := ((Ln - State.LogicBlocks[TargetBlk].StartLine) div MaxIntVal(1, Options.BlockChunkSize)) + 1;
Result[N].NavHint := '--find "#' + IntToStr(State.LogicBlocks[TargetBlk].Id) +
'" --give-block ' + IntToStr(TargetChunk);
end
else
Result[N].NavHint := '--lines ' + FileDisplay(FIdx) + ':' +
IntToStr(MaxIntVal(1, Ln - 5)) + '-' + IntToStr(Ln + 15);
end;

begin
Result := nil;
Seen := nil;
if (FileIdx < 0) or (FileIdx >= Length(State.Files)) then
Exit;

Toks := State.Files[FileIdx].Tokens;
for I := 0 to High(Toks) do
begin
if (Toks[I].Line < ChunkStartLn) or (Toks[I].Line > ChunkEndLn) then
Continue;
if (Toks[I].Kind <> tkIdent) or IsPascalKeyword(Toks[I].Lower) then
Continue;

Ident := Toks[I].Text;
LowId := Toks[I].Lower;
AlreadySeen := False;
for J := 0 to High(Seen) do
  if Seen[J] = LowId then
  begin
    AlreadySeen := True;
    Break;
  end;
if AlreadySeen then
  Continue;

SetLength(Seen, Length(Seen) + 1);
Seen[High(Seen)] := LowId;

FoundLocal := False;
if (OwnerRtnIdx >= 0) and (OwnerRtnIdx < Length(State.Routines)) then
begin
  for K := 0 to High(State.Routines[OwnerRtnIdx].Params) do
    if SameText(State.Routines[OwnerRtnIdx].Params[K].Name, Ident) then
    begin
      AddProv(Ident, 'param', State.Routines[OwnerRtnIdx].Params[K].Detail,
        State.Routines[OwnerRtnIdx].FileIdx,
        State.Routines[OwnerRtnIdx].Params[K].Sites[0].Line);
      FoundLocal := True;
      Break;
    end;

  if not FoundLocal then
    for K := 0 to High(State.Routines[OwnerRtnIdx].Locals) do
      if SameText(State.Routines[OwnerRtnIdx].Locals[K].Name, Ident) then
      begin
        AddProv(Ident, 'local', State.Routines[OwnerRtnIdx].Locals[K].Detail,
          State.Routines[OwnerRtnIdx].FileIdx,
          State.Routines[OwnerRtnIdx].Locals[K].Sites[0].Line);
        FoundLocal := True;
        Break;
      end;

  for K := 0 to High(State.Routines[OwnerRtnIdx].Assigns) do
    if SameText(Copy(State.Routines[OwnerRtnIdx].Assigns[K].Name, 1, Length(Ident)), Ident) and
       (Length(State.Routines[OwnerRtnIdx].Assigns[K].Sites) > 0) and
       (State.Routines[OwnerRtnIdx].Assigns[K].Sites[0].Line < ChunkStartLn) then
    begin
      AddProv(Ident, 'prior-assign', State.Routines[OwnerRtnIdx].Assigns[K].Name,
        State.Routines[OwnerRtnIdx].Assigns[K].Sites[0].FileIdx,
        State.Routines[OwnerRtnIdx].Assigns[K].Sites[0].Line);
      Break;
    end;
end;

if FoundLocal then
  Continue;

for K := 0 to High(State.Globals) do
  if SameText(State.Globals[K].Name, Ident) then
  begin
    if State.Globals[K].IsConst then
      AddProv(Ident, 'const', State.Globals[K].Detail, State.Globals[K].FileIdx, State.Globals[K].Line)
    else
      AddProv(Ident, 'global', State.Globals[K].Detail, State.Globals[K].FileIdx, State.Globals[K].Line);
    Break;
  end;

for K := 0 to High(State.Types) do
  if SameText(State.Types[K].Name, Ident) then
  begin
    AddProv(Ident, 'type', State.Types[K].Kind, State.Types[K].FileIdx, State.Types[K].StartLine);
    Break;
  end;

for K := 0 to High(State.Routines) do
  if SameText(State.Routines[K].Name, Ident) then
  begin
    AddProv(Ident, State.Routines[K].Kind, State.Routines[K].ReturnType,
      State.Routines[K].FileIdx, State.Routines[K].StartLine);
    Break;
  end;


end;
end;

{ ============================================================================
Report Formatting (Text, Include Tree, Logic Block Tree, Chunk View, JSON)
============================================================================ }

procedure EmitSourceSliceText(SL: TStringList; FileIdx, StartLn, EndLn: Integer;
const Indent: string; HighlightLine: Integer = -1);
var
Ln: Integer;
Marker: string;
begin
if (FileIdx < 0) or (FileIdx >= Length(State.Files)) then
Exit;
if StartLn < 1 then
StartLn := 1;
if EndLn > Length(State.Files[FileIdx].Lines) then
EndLn := Length(State.Files[FileIdx].Lines);
if StartLn > EndLn then
Exit;

SL.Add(Indent + 'source (' + FileDisplay(FileIdx) + ':' +
IntToStr(StartLn) + '..' + IntToStr(EndLn) + '):');
for Ln := StartLn to EndLn do
begin
if Ln = HighlightLine then
Marker := '>>> '
else
Marker := '    ';
SL.Add(Indent + Marker + Format('%5d | %s', [Ln, GetLineRaw(FileIdx, Ln)]));
end;
end;

function ParseLinesSliceSpec(const Spec: string; out OutFileIdx, OutStart, OutEnd: Integer;
out ErrMsg: string): Boolean;
var
ColonPos, DotsPos, DashPos, I: Integer;
FilePart, RangePart, BaseName: string;
begin
Result := False;
ErrMsg := '';
OutFileIdx := 0;
OutStart := 1;
OutEnd := 1;

ColonPos := LastDelimiter(':', Spec);
if ColonPos > 0 then
begin
FilePart := Copy(Spec, 1, ColonPos - 1);
RangePart := Copy(Spec, ColonPos + 1, MaxInt);
OutFileIdx := -1;
for I := 0 to High(State.Files) do
begin
BaseName := ExtractFileName(State.Files[I].DisplayName);
if SameFilePath(State.Files[I].DisplayName, FilePart) or SameFilePath(BaseName, FilePart) then
begin
OutFileIdx := I;
Break;
end;
end;
if OutFileIdx < 0 then
begin
ErrMsg := 'File not in audited set: ' + FilePart;
Exit;
end;
end
else
begin
RangePart := Spec;
if Length(State.Files) = 0 then
begin
ErrMsg := 'No files parsed';
Exit;
end;
end;

DotsPos := Pos('..', RangePart);
DashPos := Pos('-', RangePart);
if DotsPos > 0 then
begin
OutStart := StrToIntDef(Trim(Copy(RangePart, 1, DotsPos - 1)), -1);
OutEnd := StrToIntDef(Trim(Copy(RangePart, DotsPos + 2, MaxInt)), -1);
end
else if DashPos > 0 then
begin
OutStart := StrToIntDef(Trim(Copy(RangePart, 1, DashPos - 1)), -1);
OutEnd := StrToIntDef(Trim(Copy(RangePart, DashPos + 1, MaxInt)), -1);
end
else
begin
OutStart := StrToIntDef(Trim(RangePart), -1);
OutEnd := OutStart;
end;

if (OutStart < 1) or (OutEnd < OutStart) then
begin
ErrMsg := 'Invalid line range: ' + RangePart;
Exit;
end;
Result := True;
end;

procedure WalkIncludeTree(SL: TStringList; FileIdx: Integer;
const Prefix: string; var Visited: TBoolArray);
var
I, TIdx: Integer;
LineStr: string;
HasNote: Boolean;
begin
if (FileIdx < 0) or (FileIdx >= Length(State.Files)) then
Exit;

for I := 0 to High(State.TreeEdges) do
begin
if State.TreeEdges[I].ParentFileIdx <> FileIdx then
Continue;
TIdx := State.TreeEdges[I].TargetFileIdx;
LineStr := Prefix + '+- Line ' + IntToStr(State.TreeEdges[I].ParentLine) +
' of ' + FileDisplay(FileIdx) + ': ' + State.TreeEdges[I].EdgeKind +
' -> ' + State.TreeEdges[I].TargetDisplay;
if (TIdx >= 0) and (TIdx < Length(State.Files)) then
LineStr := LineStr + ' (' + IntToStr(Length(State.Files[TIdx].Lines)) + ' lines)';

HasNote := False;
if State.TreeEdges[I].InsideRoutine <> '' then
begin
  LineStr := LineStr + ' [inside ' + State.TreeEdges[I].InsideRoutine;
  HasNote := True;
end;
if (TIdx >= 0) and Visited[TIdx] then
begin
  if HasNote then
    LineStr := LineStr + ', already included above'
  else
    LineStr := LineStr + ' [already included above';
  HasNote := True;
end;
if HasNote then
  LineStr := LineStr + ']';
SL.Add(LineStr);

if (TIdx >= 0) and (not Visited[TIdx]) then
begin
  Visited[TIdx] := True;
  WalkIncludeTree(SL, TIdx, Prefix + '   ', Visited);
end;


end;
end;

function LogicBlockTypeTag(Kind: TLogicBlockKind): string;
begin
  case Kind of
    bkRoutine: Result := 'ROUT';
    bkType: Result := 'TDEF';
    bkBegin: Result := 'BODY';
    bkIf: Result := 'COND';
    bkElse: Result := 'COND';
    bkFor: Result := 'LOOP';
    bkWhile: Result := 'LOOP';
    bkRepeat: Result := 'LOOP';
    bkCase: Result := 'CASE';
    bkTry: Result := 'EXCP';
    bkExcept: Result := 'EXCP';
    bkFinally: Result := 'EXCP';
    bkWith: Result := 'WITH';
    bkAsm: Result := 'ASM_';
    bkUnitSection: Result := 'HEAD';
    bkDeclSection: Result := 'DECL';
    bkForwardDecl: Result := 'FWRD';
    bkInitBlock: Result := 'INIT';
    bkGap: Result := 'GAP_';
  else
    Result := 'BLCK';
  end;
end;

procedure WalkLogicBlockTree(SL: TStringList; BlkIdx, LogicalDepth: Integer;
const Prefix: string);
var
ShowNode: Boolean;
SpanLines, TotalChunks, NextDepth, CIdx, RtnIdx, K: Integer;
NodeLine, VarSummary, NextPrefix: string;
begin
if (BlkIdx < 0) or (BlkIdx >= Length(State.LogicBlocks)) then
Exit;
if (Options.MaxTreeDepth >= 0) and (LogicalDepth > Options.MaxTreeDepth) then
Exit;

ShowNode := True;
case State.LogicBlocks[BlkIdx].Kind of
bkRoutine:
if Options.HideFuncs then ShowNode := False;
bkBegin, bkIf, bkElse, bkFor, bkWhile, bkRepeat, bkCase, bkTry, bkExcept, bkFinally, bkWith, bkAsm:
if Options.HideBlocks then ShowNode := False;
end;

if ShowNode then
begin
SpanLines := State.LogicBlocks[BlkIdx].EndLine - State.LogicBlocks[BlkIdx].StartLine + 1;
TotalChunks := (SpanLines + MaxIntVal(1, Options.BlockChunkSize) - 1) div MaxIntVal(1, Options.BlockChunkSize);
NodeLine := Prefix + '+- [' + LogicBlockTypeTag(State.LogicBlocks[BlkIdx].Kind) + ' #' +
IntToStr(State.LogicBlocks[BlkIdx].Id) + '] ' +
State.LogicBlocks[BlkIdx].LabelText + ' (Lines ' +
IntToStr(State.LogicBlocks[BlkIdx].StartLine) + '..' +
IntToStr(State.LogicBlocks[BlkIdx].EndLine) + ', ' + IntToStr(SpanLines) + ' lines';
if TotalChunks > 1 then
NodeLine := NodeLine + ', ' + IntToStr(TotalChunks) + ' chunks @' + IntToStr(Options.BlockChunkSize);
if GSPathAtLine(State.LogicBlocks[BlkIdx].FileIdx, State.LogicBlocks[BlkIdx].StartLine) <> '' then
  NodeLine := NodeLine + ') [hint: --gsline ' +
    GSPathAtLine(State.LogicBlocks[BlkIdx].FileIdx, State.LogicBlocks[BlkIdx].StartLine) +
    '; --find "#' + IntToStr(State.LogicBlocks[BlkIdx].Id) + '" --give-block 1]'
else
  NodeLine := NodeLine + ') [hint: --find "#' + IntToStr(State.LogicBlocks[BlkIdx].Id) + '" --give-block 1]';
SL.Add(NodeLine);

if (State.LogicBlocks[BlkIdx].Kind = bkRoutine) and (not Options.HideVars) then
begin
  RtnIdx := State.LogicBlocks[BlkIdx].OwnerRoutineIdx;
  if (RtnIdx >= 0) and (RtnIdx < Length(State.Routines)) then
  begin
    if Length(State.Routines[RtnIdx].Params) > 0 then
    begin
      VarSummary := Prefix + '   params: ';
      for K := 0 to High(State.Routines[RtnIdx].Params) do
      begin
        if K > 0 then VarSummary := VarSummary + ', ';
        VarSummary := VarSummary + State.Routines[RtnIdx].Params[K].Name + ':' +
          State.Routines[RtnIdx].Params[K].Detail;
      end;
      SL.Add(VarSummary);
    end;
    if Length(State.Routines[RtnIdx].Locals) > 0 then
    begin
      VarSummary := Prefix + '   locals: ';
      for K := 0 to High(State.Routines[RtnIdx].Locals) do
      begin
        if K > 0 then VarSummary := VarSummary + ', ';
        VarSummary := VarSummary + State.Routines[RtnIdx].Locals[K].Name + ':' +
          State.Routines[RtnIdx].Locals[K].Detail;
      end;
      SL.Add(VarSummary);
    end;
  end;
end;

NextDepth := LogicalDepth + 1;
NextPrefix := Prefix + '   ';


end
else
begin
NextDepth := LogicalDepth;
NextPrefix := Prefix;
end;

for CIdx := 0 to High(State.LogicBlocks[BlkIdx].Children) do
WalkLogicBlockTree(SL, State.LogicBlocks[BlkIdx].Children[CIdx], NextDepth, NextPrefix);
end;

procedure EmitUsageListText(SL: TStringList; const List: TUsageItemArray;
OwnerFileIdx: Integer; const Indent: string);
var
I, J, SFile, SLine: Integer;
LineStr: string;
begin
for I := 0 to High(List) do
for J := 0 to High(List[I].Sites) do
begin
SFile := List[I].Sites[J].FileIdx;
SLine := List[I].Sites[J].Line;
LineStr := Indent;
if SFile <> OwnerFileIdx then
LineStr := LineStr + '"' + FileDisplay(SFile) + '": ';
LineStr := LineStr + 'Line ' + IntToStr(SLine) + ': ' + List[I].Name;
if List[I].Detail <> '' then
LineStr := LineStr + ':' + List[I].Detail;
SL.Add(LineStr + ';');
end;
end;

procedure EmitUsageListJson(SL: TStringList; const PropName: string;
const List: TUsageItemArray; const Indent: string);
var
I, J, TotalSites, Emitted: Integer;
begin
TotalSites := 0;
for I := 0 to High(List) do
Inc(TotalSites, Length(List[I].Sites));

SL.Add(Indent + '"' + PropName + '": [');
Emitted := 0;
for I := 0 to High(List) do
for J := 0 to High(List[I].Sites) do
begin
Inc(Emitted);
SL.Add(Indent + '  {"name": "' + JsonEscape(List[I].Name) +
'", "detail": "' + JsonEscape(List[I].Detail) +
'", "file": "' + JsonEscape(FileDisplay(List[I].Sites[J].FileIdx)) +
'", "line": ' + IntToStr(List[I].Sites[J].Line) + '}' +
JsonSep(Emitted = TotalSites));
end;
SL.Add(Indent + '],');
end;

function FilterSearchHitsByScope(const Hits: TSearchHitArray; const ScopeTarget: string): TSearchHitArray;
var
  BM: TBlockMatch;
  B: TLogicBlock;
  I, OutN: Integer;
  InScope: Boolean;
begin
  Result := Hits;
  if Trim(ScopeTarget) = '' then
    Exit;
  BM := FindScopedBlockMatch(ScopeTarget);
  if (not BM.Found) or (BM.BlockIdx < 0) or (BM.BlockIdx >= Length(State.LogicBlocks)) then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  B := State.LogicBlocks[BM.BlockIdx];
  OutN := 0;
  SetLength(Result, 0);
  for I := 0 to High(Hits) do
  begin
    InScope := (Hits[I].FileIdx = B.FileIdx) and
               (Hits[I].StartLine >= B.StartLine) and
               (Hits[I].EndLine <= B.EndLine);
    { If block spans files, allow hits in end-file tail conservatively }
    if (not InScope) and (B.EndFileIdx <> B.FileIdx) then
      InScope := ((Hits[I].FileIdx = B.FileIdx) and (Hits[I].StartLine >= B.StartLine)) or
                 ((Hits[I].FileIdx = B.EndFileIdx) and (Hits[I].EndLine <= B.EndLine)) or
                 ((Hits[I].FileIdx <> B.FileIdx) and (Hits[I].FileIdx <> B.EndFileIdx));
    { simple case above for middle files is permissive but rare; prefer strict for same-file }
    if (B.EndFileIdx = B.FileIdx) then
      InScope := (Hits[I].FileIdx = B.FileIdx) and
                 (Hits[I].StartLine >= B.StartLine) and
                 (Hits[I].EndLine <= B.EndLine);
    if InScope then
    begin
      SetLength(Result, OutN + 1);
      Result[OutN] := Hits[I];
      Inc(OutN);
    end;
  end;
end;

function FilterCallerHitsByScope(const Hits: TCallerHitArray;
  const ScopeTarget: string): TCallerHitArray;
var
  BM: TBlockMatch;
  B: TLogicBlock;
  I, N: Integer;
begin
  Result := Hits;
  if Trim(ScopeTarget) = '' then Exit;
  BM := FindScopedBlockMatch(ScopeTarget);
  if not BM.Found then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  B := State.LogicBlocks[BM.BlockIdx];
  N := 0;
  SetLength(Result, 0);
  for I := 0 to High(Hits) do
    if (Hits[I].FileIdx = B.FileIdx) and
       (Hits[I].Line >= B.StartLine) and
       (Hits[I].Line <= B.EndLine) then
    begin
      SetLength(Result, N + 1);
      Result[N] := Hits[I];
      Inc(N);
    end;
end;


procedure ResolveBlockChunk(var BlockIdx: Integer; MatchLine: Integer;
  out TotalChunks, ActiveChunk, ChunkStart, ChunkEnd: Integer);
var
  Step, SpanLines: Integer;
begin
  for Step := 1 to Options.WidenBlockSteps do
    if State.LogicBlocks[BlockIdx].ParentIdx >= 0 then
      BlockIdx := State.LogicBlocks[BlockIdx].ParentIdx;

  SpanLines := State.LogicBlocks[BlockIdx].EndLine - State.LogicBlocks[BlockIdx].StartLine + 1;
  TotalChunks := (SpanLines + MaxIntVal(1, Options.BlockChunkSize) - 1) div MaxIntVal(1, Options.BlockChunkSize);
  if Options.GiveBlockSpecified and (Options.GiveBlockNum >= 1) then
    ActiveChunk := MinIntVal(Options.GiveBlockNum, TotalChunks)
  else
    ActiveChunk := ((MatchLine - State.LogicBlocks[BlockIdx].StartLine) div MaxIntVal(1, Options.BlockChunkSize)) + 1;

  ChunkStart := State.LogicBlocks[BlockIdx].StartLine + (ActiveChunk - 1) * Options.BlockChunkSize;
  ChunkEnd := MinIntVal(State.LogicBlocks[BlockIdx].EndLine, ChunkStart + Options.BlockChunkSize - 1);
end;

function InFindScope(FIdx, Ln: Integer): Boolean;
begin

  if Options.ScopeBlockIdx < 0 then Exit(True);
  Result := (State.LogicBlocks[Options.ScopeBlockIdx].FileIdx = FIdx) and
            (Ln >= State.LogicBlocks[Options.ScopeBlockIdx].StartLine) and
            (Ln <= State.LogicBlocks[Options.ScopeBlockIdx].EndLine);
end;

function GetScopedSearchHits(const Pattern, Scope: string): TSearchHitArray;
begin
  Result := RunPascalTokenSearch(Pattern);
  if Trim(Scope) <> '' then
    Result := FilterSearchHitsByScope(Result, Scope);
end;

function GetScopedCallerHits(const Target, Scope: string): TCallerHitArray;
begin
  Result := FindCallersOf(Target);
  if Trim(Scope) <> '' then
    Result := FilterCallerHitsByScope(Result, Scope);
end;


function BuildJsonReport(ExitCode: Integer): string;
var
SL: TStringList;
Unimpl, I, J, T, G, P, F, R, V, TotalVars, EmittedVars, SF, SA, SB: Integer;
CurBlk, TotalChunks, ActiveChunk, ChunkStart, ChunkEnd: Integer;
CHits: TCallerHitArray;
SHits: TSearchHitArray;
BMatch: TBlockMatch;
Provs: TProvenanceEntryArray;
ErrStr: string;
  OReachable: TBoolArray;
  HasEntryRoots: Boolean;
  EntrySeeded, OrphanCount, OI: Integer;
  JsonOrder: TIntArray;
  JI, JJ, JT: Integer;
begin
SL := TStringList.Create;
try
Unimpl := CountUnimplementedDecls;
SL.Add('{');
SL.Add('  "schema_version": 1,');
  SL.Add('  "tool_version": "' + FPCAUDIT_VERSION + '",');
SL.Add('  "parser_version": 2,');
SL.Add('  "exit_code": ' + IntToStr(ExitCode) + ',');
SL.Add('  "cached": ' + JsonBool(CacheLoaded) + ',');
SL.Add('  "summary": {');
SL.Add('    "files": ' + IntToStr(Length(State.Files)) + ',');
SL.Add('    "types": ' + IntToStr(Length(State.Types)) + ',');
SL.Add('    "routines": ' + IntToStr(Length(State.Routines)) + ',');
SL.Add('    "logic_blocks": ' + IntToStr(Length(State.LogicBlocks)) + ',');
SL.Add('    "syntax_issues": ' + IntToStr(Length(State.Diags)) + ',');
SL.Add('    "unimplemented_decls": ' + IntToStr(Unimpl));
SL.Add('  },');

SL.Add('  "files": [');
for F := 0 to High(State.Files) do
  SL.Add('    {"file": "' + JsonEscape(State.Files[F].DisplayName) +
    '", "lines": ' + IntToStr(Length(State.Files[F].Lines)) + '}' +
    JsonSep(F = High(State.Files)));
SL.Add('  ],');

SL.Add('  "tree_edges": [');
for I := 0 to High(State.TreeEdges) do
  SL.Add('    {"parent_file": "' + JsonEscape(FileDisplay(State.TreeEdges[I].ParentFileIdx)) +
    '", "parent_line": ' + IntToStr(State.TreeEdges[I].ParentLine) +
    ', "kind": "' + JsonEscape(State.TreeEdges[I].EdgeKind) +
    '", "target": "' + JsonEscape(State.TreeEdges[I].TargetDisplay) +
    '", "inside_routine": "' + JsonEscape(State.TreeEdges[I].InsideRoutine) + '"}' +
    JsonSep(I = High(State.TreeEdges)));
SL.Add('  ],');

SL.Add('  "logic_tree": [');
JsonOrder := nil;
for I := 0 to High(State.LogicBlocks) do
begin
  SetLength(JsonOrder, Length(JsonOrder) + 1);
  JsonOrder[High(JsonOrder)] := I;
end;
for JI := 1 to High(JsonOrder) do
begin
  JT := JsonOrder[JI];
  JJ := JI - 1;
  while (JJ >= 0) and
        ((State.LogicBlocks[JsonOrder[JJ]].FileIdx > State.LogicBlocks[JT].FileIdx) or
         ((State.LogicBlocks[JsonOrder[JJ]].FileIdx = State.LogicBlocks[JT].FileIdx) and
          (State.LogicBlocks[JsonOrder[JJ]].StartLine > State.LogicBlocks[JT].StartLine))) do
  begin
    JsonOrder[JJ + 1] := JsonOrder[JJ];
    Dec(JJ);
  end;
  JsonOrder[JJ + 1] := JT;
end;
for JI := 0 to High(JsonOrder) do
begin
  I := JsonOrder[JI];
  SL.Add('    {"id": ' + IntToStr(State.LogicBlocks[I].Id) +
    ', "type": "' + LogicBlockTypeTag(State.LogicBlocks[I].Kind) +
    '", "label": "' + JsonEscape(State.LogicBlocks[I].LabelText) +
    '", "parent_id": ' + IntToStr(State.LogicBlocks[I].ParentIdx + 1) +
    ', "depth": ' + IntToStr(State.LogicBlocks[I].Depth) +
    ', "file": "' + JsonEscape(FileDisplay(State.LogicBlocks[I].FileIdx)) +
    '", "start_line": ' + IntToStr(State.LogicBlocks[I].StartLine) +
    ', "end_line": ' + IntToStr(State.LogicBlocks[I].EndLine) + '}' +
    JsonSep(JI = High(JsonOrder)));
end;
SL.Add('  ],');

SL.Add('  "diagnostics": [');
for I := 0 to High(State.Diags) do
  SL.Add('    {"file": "' + JsonEscape(FileDisplay(State.Diags[I].FileIdx)) +
    '", "line": ' + IntToStr(State.Diags[I].Line) +
    ', "col": ' + IntToStr(State.Diags[I].Col) +
    ', "bit": ' + IntToStr(State.Diags[I].CategoryBit) +
    ', "message": "' + JsonEscape(State.Diags[I].Message) +
    '", "snippet": "' + JsonEscape(State.Diags[I].Snippet) + '"}' +
    JsonSep(I = High(State.Diags)));
SL.Add('  ],');

SL.Add('  "types": [');
J := 0;
for T := 0 to High(State.Types) do
  if StrContainsCI(State.Types[T].Name, Options.FindPattern) and InFindScope(State.Types[T].FileIdx, State.Types[T].StartLine) then
    Inc(J);
I := 0;
for T := 0 to High(State.Types) do
begin
  if not (StrContainsCI(State.Types[T].Name, Options.FindPattern) and InFindScope(State.Types[T].FileIdx, State.Types[T].StartLine)) then
    Continue;
  Inc(I);
  SL.Add('    {"name": "' + JsonEscape(State.Types[T].Name) +
    '", "kind": "' + JsonEscape(State.Types[T].Kind) +
    '", "file": "' + JsonEscape(FileDisplay(State.Types[T].FileIdx)) +
    '", "start_line": ' + IntToStr(State.Types[T].StartLine) +
    ', "end_line": ' + IntToStr(State.Types[T].EndLine) + '}' +
    JsonSep(I = J));
end;
SL.Add('  ],');

SL.Add('  "globals": [');
J := 0;
for G := 0 to High(State.Globals) do
  if StrContainsCI(State.Globals[G].Name, Options.FindPattern) and InFindScope(State.Globals[G].FileIdx, State.Globals[G].Line) then
    Inc(J);
I := 0;
for G := 0 to High(State.Globals) do
begin
  if not (StrContainsCI(State.Globals[G].Name, Options.FindPattern) and InFindScope(State.Globals[G].FileIdx, State.Globals[G].Line)) then
    Continue;
  Inc(I);
  SL.Add('    {"name": "' + JsonEscape(State.Globals[G].Name) +
    '", "is_const": ' + JsonBool(State.Globals[G].IsConst) +
    ', "detail": "' + JsonEscape(State.Globals[G].Detail) +
    '", "file": "' + JsonEscape(FileDisplay(State.Globals[G].FileIdx)) +
    '", "line": ' + IntToStr(State.Globals[G].Line) + '}' +
    JsonSep(I = J));
end;
SL.Add('  ],');

SL.Add('  "forwards": [');
J := 0;
for P := 0 to High(State.Forwards) do
  if StrContainsCI(State.Forwards[P].Name, Options.FindPattern) and InFindScope(State.Forwards[P].FileIdx, State.Forwards[P].Line) then
    Inc(J);
I := 0;
for P := 0 to High(State.Forwards) do
begin
  if not (StrContainsCI(State.Forwards[P].Name, Options.FindPattern) and InFindScope(State.Forwards[P].FileIdx, State.Forwards[P].Line)) then
    Continue;
  Inc(I);
  SL.Add('    {"name": "' + JsonEscape(State.Forwards[P].Name) +
    '", "kind": "' + JsonEscape(State.Forwards[P].Kind) +
    '", "signature": "' + JsonEscape(State.Forwards[P].Signature) +
    '", "file": "' + JsonEscape(FileDisplay(State.Forwards[P].FileIdx)) +
    '", "line": ' + IntToStr(State.Forwards[P].Line) +
    ', "requires_impl": ' + JsonBool(State.Forwards[P].RequiresImpl) +
    ', "implemented": ' + JsonBool(State.Forwards[P].ImplFileIdx >= 0) + '}' +
    JsonSep(I = J));
end;
SL.Add('  ],');

SL.Add('  "routines": [');
J := 0;
for R := 0 to High(State.Routines) do
  if StrContainsCI(State.Routines[R].Name, Options.FindPattern) and InFindScope(State.Routines[R].FileIdx, State.Routines[R].StartLine) then
    Inc(J);
I := 0;
for R := 0 to High(State.Routines) do
begin
  if not (StrContainsCI(State.Routines[R].Name, Options.FindPattern) and InFindScope(State.Routines[R].FileIdx, State.Routines[R].StartLine)) then
    Continue;
  Inc(I);
  SL.Add('    {');
  SL.Add('      "name": "' + JsonEscape(State.Routines[R].Name) + '",');
  SL.Add('      "kind": "' + JsonEscape(State.Routines[R].Kind) + '",');
  SL.Add('      "return_type": "' + JsonEscape(State.Routines[R].ReturnType) + '",');
  SL.Add('      "file": "' + JsonEscape(FileDisplay(State.Routines[R].FileIdx)) + '",');
  SL.Add('      "start_line": ' + IntToStr(State.Routines[R].StartLine) + ',');
  SL.Add('      "end_line": ' + IntToStr(State.Routines[R].EndLine) + ',');
  EmitUsageListJson(SL, 'params', State.Routines[R].Params, '      ');
  EmitUsageListJson(SL, 'locals', State.Routines[R].Locals, '      ');
  EmitUsageListJson(SL, 'assigns', State.Routines[R].Assigns, '      ');
  EmitUsageListJson(SL, 'calls', State.Routines[R].Calls, '      ');
  TotalVars := 0;
  for V := 0 to High(State.Routines[R].Vars) do
    Inc(TotalVars, Length(State.Routines[R].Vars[V].Sites));
  EmittedVars := 0;
  SL.Add('      "vars": [');
  for V := 0 to High(State.Routines[R].Vars) do
    for P := 0 to High(State.Routines[R].Vars[V].Sites) do
    begin
      Inc(EmittedVars);
      SL.Add('        {"name": "' + JsonEscape(State.Routines[R].Vars[V].Name) +
        '", "detail": "' + JsonEscape(State.Routines[R].Vars[V].Detail) +
        '", "file": "' + JsonEscape(FileDisplay(State.Routines[R].Vars[V].Sites[P].FileIdx)) +
        '", "line": ' + IntToStr(State.Routines[R].Vars[V].Sites[P].Line) + '}' +
        JsonSep(EmittedVars = TotalVars));
    end;
  SL.Add('      ]');
  SL.Add('    }' + JsonSep(I = J));
end;
SL.Add('  ],');

if Options.GiveBlockSpecified or (Options.WidenBlockSteps > 0) then
begin
  BMatch := FindScopedBlockMatch(Options.FindPattern);
  SL.Add('  "scoped_block": {');
  SL.Add('    "found": ' + JsonBool(BMatch.Found) + ',');
  if BMatch.Found and (BMatch.BlockIdx >= 0) then
  begin
    CurBlk := BMatch.BlockIdx;
    ResolveBlockChunk(CurBlk, BMatch.MatchLine, TotalChunks, ActiveChunk, ChunkStart, ChunkEnd);


    SL.Add('    "block_id": ' + IntToStr(State.LogicBlocks[CurBlk].Id) + ',');
    SL.Add('    "label": "' + JsonEscape(State.LogicBlocks[CurBlk].LabelText) + '",');
    SL.Add('    "file": "' + JsonEscape(FileDisplay(State.LogicBlocks[CurBlk].FileIdx)) + '",');
    SL.Add('    "chunk": ' + IntToStr(ActiveChunk) + ',');
    SL.Add('    "total_chunks": ' + IntToStr(TotalChunks) + ',');
    SL.Add('    "start_line": ' + IntToStr(ChunkStart) + ',');
    SL.Add('    "end_line": ' + IntToStr(ChunkEnd) + ',');
    SL.Add('    "lines": [');
    for I := ChunkStart to ChunkEnd do
      SL.Add('      {"line": ' + IntToStr(I) + ', "text": "' +
        JsonEscape(GetLineRaw(State.LogicBlocks[CurBlk].FileIdx, I)) + '"}' +
        JsonSep(I = ChunkEnd));
    SL.Add('    ],');

    Provs := CollectChunkProvenance(State.LogicBlocks[CurBlk].FileIdx, ChunkStart, ChunkEnd,
      State.LogicBlocks[CurBlk].OwnerRoutineIdx);
    SL.Add('    "provenance": [');
    for I := 0 to High(Provs) do
      SL.Add('      {"symbol": "' + JsonEscape(Provs[I].SymbolName) +
        '", "kind": "' + JsonEscape(Provs[I].KindLabel) +
        '", "detail": "' + JsonEscape(Provs[I].Detail) +
        '", "file": "' + JsonEscape(FileDisplay(Provs[I].FileIdx)) +
        '", "line": ' + IntToStr(Provs[I].Line) +
        ', "hint": "' + JsonEscape(Provs[I].NavHint) + '"}' +
        JsonSep(I = High(Provs)));
    SL.Add('    ]');
  end
  else
    SL.Add('    "query": "' + JsonEscape(Options.FindPattern) + '"');

  SL.Add('  },');
end;

if Trim(Options.CallersTarget) <> '' then
begin
  CHits := GetScopedCallerHits(Options.CallersTarget, Options.SearchInTarget);

  SL.Add('  "callers": [');
  for I := 0 to High(CHits) do
    SL.Add('    {"caller": "' + JsonEscape(CHits[I].CallerRoutine) +
      '", "file": "' + JsonEscape(FileDisplay(CHits[I].FileIdx)) +
      '", "line": ' + IntToStr(CHits[I].Line) +
      ', "call": "' + JsonEscape(CHits[I].CallText) + '"}' +
      JsonSep(I = High(CHits)));
  SL.Add('  ],');
end;
if Options.OrphansMode then
begin
  ComputeRoutineReachability(OReachable, HasEntryRoots, EntrySeeded);
  OrphanCount := 0;
  for OI := 0 to High(OReachable) do
    if not OReachable[OI] then
      Inc(OrphanCount);
  SL.Add('  "orphans": {');
  SL.Add('    "has_entry_roots": ' + JsonBool(HasEntryRoots) + ',');
  SL.Add('    "entry_seeded": ' + IntToStr(EntrySeeded) + ',');
  SL.Add('    "count": ' + IntToStr(OrphanCount) + ',');
  SL.Add('    "routines": [');
  OI := 0;
  for R := 0 to High(State.Routines) do
    if not OReachable[R] then
    begin
      Inc(OI);
      SL.Add('      {"name": "' + JsonEscape(State.Routines[R].Name) +
        '", "kind": "' + JsonEscape(State.Routines[R].Kind) +
        '", "file": "' + JsonEscape(FileDisplay(State.Routines[R].FileIdx)) +
        '", "start_line": ' + IntToStr(State.Routines[R].StartLine) +
        ', "end_line": ' + IntToStr(State.Routines[R].EndLine) + '}' +
        JsonSep(OI = OrphanCount));
    end;
  SL.Add('    ]');
  SL.Add('  },');
end;



if Trim(Options.SearchPattern) <> '' then
begin
  SHits := GetScopedSearchHits(Options.SearchPattern, Options.SearchInTarget);

  SL.Add('  "search_matches": [');
  for I := 0 to High(SHits) do
    SL.Add('    {"file": "' + JsonEscape(FileDisplay(SHits[I].FileIdx)) +
      '", "start_line": ' + IntToStr(SHits[I].StartLine) +
      ', "end_line": ' + IntToStr(SHits[I].EndLine) +
      ', "col": ' + IntToStr(SHits[I].Col) +
      ', "snippet": "' + JsonEscape(SHits[I].Snippet) + '"}' +
      JsonSep(I = High(SHits)));
  SL.Add('  ],');
end;

if Trim(Options.LinesSliceSpec) <> '' then
begin
  SL.Add('  "lines_slice": {');
  if not ParseLinesSliceSpec(Options.LinesSliceSpec, SF, SA, SB, ErrStr) then
    SL.Add('    "error": "' + JsonEscape(ErrStr) + '"')
  else
  begin
    if SA < 1 then SA := 1;
    if SB > Length(State.Files[SF].Lines) then SB := Length(State.Files[SF].Lines);
    SL.Add('    "file": "' + JsonEscape(FileDisplay(SF)) + '",');
    SL.Add('    "start_line": ' + IntToStr(SA) + ',');
    SL.Add('    "end_line": ' + IntToStr(SB) + ',');
    SL.Add('    "lines": [');
    for I := SA to SB do
      SL.Add('      {"line": ' + IntToStr(I) + ', "text": "' +
        JsonEscape(GetLineRaw(SF, I)) + '"}' + JsonSep(I = SB));
    SL.Add('    ]');
  end;
  SL.Add('  },');
end;

SL.Add('  "complete": true');
SL.Add('}');
Result := SL.Text;


finally
SL.Free;
end;
end;

function BuildTextReport(ExitCode: Integer): string;
var
SL: TStringList;
Unimpl, I, F, T, G, P, R, K, SF, SA, SB, CurBlk: Integer;
TotalChunks, ActiveChunk, ChunkStart, ChunkEnd, CurChain, NextWiden: Integer;
Visited: TBoolArray;
SHits: TSearchHitArray;
CHits: TCallerHitArray;
BMatch: TBlockMatch;
Provs: TProvenanceEntryArray;
ErrStr, SigStr, ChainStr, CacheTag: string;
HasContent, HdrPrinted, AnyPerFile: Boolean;
  OReachable: TBoolArray;
  HasEntryRoots: Boolean;
  EntrySeeded, OrphanCount, OI: Integer;
  RootOrder: TIntArray;
  RI, RJ, RTmp, RCnt: Integer;

begin
SL := TStringList.Create;
try
Unimpl := CountUnimplementedDecls;
if CacheLoaded then
CacheTag := ' | Cache: hit'
else
CacheTag := '';

SL.Add('GSLine paths are the primary statement handles (use -gsline); -glines is deprecated.');
SL.Add('================================================================');
SL.Add('FPCTOOLS AUDIT REPORT (fpctools ' + FPCAUDIT_VERSION + ', parser ' + IntToStr(FPCAUDIT_PARSER_VERSION) + ')');
SL.Add('Files parsed: ' + IntToStr(Length(State.Files)) +
  ' | Types: ' + IntToStr(Length(State.Types)) +
  ' | Routines: ' + IntToStr(Length(State.Routines)) +
  ' | Syntax issues: ' + IntToStr(Length(State.Diags)) +
  ' | Unimplemented decls: ' + IntToStr(Unimpl) +
  ' | ExitMask: ' + IntToStr(ExitCode) + CacheTag);
SL.Add('================================================================');
SL.Add('');

{ Scoped Block & Chunk Retrieval (--find ... --give-block / --widen) }
if Options.GiveBlockSpecified or (Options.WidenBlockSteps > 0) then
begin
  SL.Add('=== SCOPED BLOCK RETRIEVAL ===');
  BMatch := FindScopedBlockMatch(Options.FindPattern);
  if not BMatch.Found then
    SL.Add('  No matching block or symbol found for query: "' + Options.FindPattern + '"')

  else
  begin
    CurBlk := BMatch.BlockIdx;
    if CurBlk >= 0 then
    begin
      ResolveBlockChunk(CurBlk, BMatch.MatchLine, TotalChunks, ActiveChunk, ChunkStart, ChunkEnd);


      SL.Add('  Block [' + LogicBlockTypeTag(State.LogicBlocks[CurBlk].Kind) + ' #' + IntToStr(State.LogicBlocks[CurBlk].Id) + ']: ' +
        State.LogicBlocks[CurBlk].LabelText + ' ("' + FileDisplay(State.LogicBlocks[CurBlk].FileIdx) +
        '": Lines ' + IntToStr(State.LogicBlocks[CurBlk].StartLine) + '..' +
        IntToStr(State.LogicBlocks[CurBlk].EndLine) + ')');
      SL.Add('  Chunk ' + IntToStr(ActiveChunk) + ' of ' + IntToStr(TotalChunks) +
        ' (block-size: ' + IntToStr(Options.BlockChunkSize) + ' lines)');
      if ActiveChunk < TotalChunks then
        SL.Add('  Next chunk hint: --find "#' + IntToStr(State.LogicBlocks[CurBlk].Id) +
          '" --give-block ' + IntToStr(ActiveChunk + 1) +
          ' --block-size ' + IntToStr(Options.BlockChunkSize));

      ChainStr := '';
      CurChain := CurBlk;
      NextWiden := 1;
      while CurChain >= 0 do
      begin
        if ChainStr <> '' then
          ChainStr := ChainStr + ' -> ';
        ChainStr := ChainStr + '[' + LogicBlockTypeTag(State.LogicBlocks[CurChain].Kind) + ' #' + IntToStr(State.LogicBlocks[CurChain].Id) + '] ' +
          State.LogicBlocks[CurChain].LabelText;
        if CurChain <> CurBlk then
        begin
          ChainStr := ChainStr + ' (--widen ' + IntToStr(NextWiden) + ')';
          Inc(NextWiden);
        end;
        CurChain := State.LogicBlocks[CurChain].ParentIdx;
      end;
      SL.Add('  Scope chain (innermost -> outermost): ' + ChainStr);

      EmitSourceSliceText(SL, State.LogicBlocks[CurBlk].FileIdx, ChunkStart, ChunkEnd,
        '  ', BMatch.MatchLine);

      Provs := CollectChunkProvenance(State.LogicBlocks[CurBlk].FileIdx, ChunkStart, ChunkEnd,
        State.LogicBlocks[CurBlk].OwnerRoutineIdx);
      if Length(Provs) > 0 then
      begin
        SL.Add('  Symbol provenance in this chunk:');
        for K := 0 to High(Provs) do
        begin
          SigStr := '    - ' + Provs[K].SymbolName + ' (' + Provs[K].KindLabel;
          if Provs[K].Detail <> '' then
            SigStr := SigStr + ': ' + Provs[K].Detail;
          SigStr := SigStr + ') at "' + FileDisplay(Provs[K].FileIdx) +
            '": Line ' + IntToStr(Provs[K].Line) + ' -> [' + Provs[K].NavHint + ']';
          SL.Add(SigStr);
        end;
      end;
    end
    else
    begin
      ChunkStart := MaxIntVal(1, BMatch.MatchLine - (Options.BlockChunkSize div 2));
      ChunkEnd := ChunkStart + Options.BlockChunkSize - 1;
      EmitSourceSliceText(SL, BMatch.MatchFileIdx, ChunkStart, ChunkEnd,
        '  ', BMatch.MatchLine);
    end;
  end;
  SL.Add('');
end;

if Trim(Options.SearchPattern) <> '' then
begin
  SHits := GetScopedSearchHits(Options.SearchPattern, Options.SearchInTarget);

  if Trim(Options.SearchInTarget) <> '' then
    SL.Add('=== PASCAL TOKEN SEARCH: ' + Options.SearchPattern + ' in ' + Options.SearchInTarget + ' (' + IntToStr(Length(SHits)) + ' match(es)) ===')
  else
    SL.Add('=== PASCAL TOKEN SEARCH: ' + Options.SearchPattern + ' (' + IntToStr(Length(SHits)) + ' match(es)) ===');
  for I := 0 to High(SHits) do
  begin
    if SHits[I].StartLine = SHits[I].EndLine then
      SL.Add('  "' + FileDisplay(SHits[I].FileIdx) + '": Line ' +
        IntToStr(SHits[I].StartLine) + ', Col ' + IntToStr(SHits[I].Col) +
        ' -> ' + SHits[I].Snippet)
    else
      SL.Add('  "' + FileDisplay(SHits[I].FileIdx) + '": Lines ' +
        IntToStr(SHits[I].StartLine) + '..' + IntToStr(SHits[I].EndLine) +
        ', Col ' + IntToStr(SHits[I].Col) + ' -> ' + SHits[I].Snippet);
  end;
  SL.Add('');
end;

if Trim(Options.CallersTarget) <> '' then
begin
  CHits := GetScopedCallerHits(Options.CallersTarget, Options.SearchInTarget);

  if Trim(Options.SearchInTarget) <> '' then
    SL.Add('=== CALLERS OF: ' + Options.CallersTarget + ' in ' + Options.SearchInTarget +
      ' (' + IntToStr(Length(CHits)) + ' site(s)) ===')
  else
    SL.Add('=== CALLERS OF: ' + Options.CallersTarget + ' (' + IntToStr(Length(CHits)) + ' site(s)) ===');
  for I := 0 to High(CHits) do
    SL.Add('  "' + FileDisplay(CHits[I].FileIdx) + '": Line ' +
      IntToStr(CHits[I].Line) + ' in ' + CHits[I].CallerRoutine + ' -> ' + CHits[I].CallText);
  SL.Add('');
end;
if Options.OrphansMode then
begin
  ComputeRoutineReachability(OReachable, HasEntryRoots, EntrySeeded);
  OrphanCount := 0;
  for OI := 0 to High(OReachable) do
    if not OReachable[OI] then
      Inc(OrphanCount);
  SL.Add('=== POTENTIAL ORPHANS / UNREACHABLE ROUTINES (' + IntToStr(OrphanCount) + ' candidate(s)) ===');
  if not HasEntryRoots then
    SL.Add('  Note: no top-level entry block (main begin/initialization/finalization) found;')
  else
    SL.Add('  Reachability seeded from top-level entry block(s); entry-referenced routines: ' + IntToStr(EntrySeeded) + '.');
  SL.Add('  Analysis is conservative and closed-world: routines may be reachable via callbacks, exports,');
  SL.Add('  published methods, external units, or calls not tracked as direct call/var references.');
  SL.Add('');
  if OrphanCount = 0 then
    SL.Add('  (none)')
  else
    for OI := 0 to High(State.Routines) do
      if not OReachable[OI] then
        SL.Add('  "' + FileDisplay(State.Routines[OI].FileIdx) + '": Line ' +
          IntToStr(State.Routines[OI].StartLine) + '  ' +
          State.Routines[OI].Kind + ' ' + State.Routines[OI].Name +
          '  (Lines ' + IntToStr(State.Routines[OI].StartLine) + '..' +
          IntToStr(State.Routines[OI].EndLine) + ')');
  SL.Add('');
end;



if Trim(Options.LinesSliceSpec) <> '' then
begin
  SL.Add('=== SOURCE LINES: ' + Options.LinesSliceSpec + ' ===');
  if not ParseLinesSliceSpec(Options.LinesSliceSpec, SF, SA, SB, ErrStr) then
    SL.Add('  [ERROR] ' + ErrStr)
  else
    EmitSourceSliceText(SL, SF, SA, SB, '  ');
  SL.Add('');
end;

if Options.ReportOpts.ShowTree then
begin
  SL.Add('=== FILE & INCLUDE TREE ===');
  if Length(State.Files) > 0 then
  begin
    SetLength(Visited, Length(State.Files));
    Visited[0] := True;
    SL.Add('+ Line 1: ' + State.Files[0].DisplayName + ' (' +
      IntToStr(Length(State.Files[0].Lines)) + ' lines)');
    WalkIncludeTree(SL, 0, '', Visited);
  end;
  SL.Add('');
end;

if Options.ReportOpts.ShowBlockTree then
begin
  SL.Add('=== LOGIC & ROUTINE BLOCK TREE ===');
  for F := 0 to High(State.Files) do
  begin
    HasContent := False;
    for I := 0 to High(State.LogicBlocks) do
      if (State.LogicBlocks[I].FileIdx = F) and (State.LogicBlocks[I].ParentIdx < 0) then
      begin
        HasContent := True;
        Break;
      end;
    if not HasContent then
      Continue;
    SL.Add('File: "' + State.Files[F].DisplayName + '"');
    { Prototype: emit root containers in document order (GAP_ blocks are appended last). }
    RootOrder := nil;
    RCnt := 0;
    for I := 0 to High(State.LogicBlocks) do
      if (State.LogicBlocks[I].FileIdx = F) and (State.LogicBlocks[I].ParentIdx < 0) then
      begin
        SetLength(RootOrder, RCnt + 1);
        RootOrder[RCnt] := I;
        Inc(RCnt);
      end;
    for RI := 1 to RCnt - 1 do
    begin
      RTmp := RootOrder[RI];
      RJ := RI - 1;
      while (RJ >= 0) and
            (State.LogicBlocks[RootOrder[RJ]].StartLine > State.LogicBlocks[RTmp].StartLine) do
      begin
        RootOrder[RJ + 1] := RootOrder[RJ];
        Dec(RJ);
      end;
      RootOrder[RJ + 1] := RTmp;
    end;
    for RI := 0 to RCnt - 1 do
      WalkLogicBlockTree(SL, RootOrder[RI], 0, '  ');
  end;
  SL.Add('');
end;

if Options.ReportOpts.ShowDiag then
begin
  SL.Add('=== SYNTAX & STRUCTURAL DIAGNOSTICS ===');
  if (Length(State.Diags) > 0) or (Unimpl > 0) then
  begin
    for I := 0 to High(State.Diags) do
    begin
      SL.Add(IntToStr(I + 1) + '. ' + GSLocationTag(State.Diags[I].FileIdx, State.Diags[I].Line) +
        '[ERROR bit=' + IntToStr(State.Diags[I].CategoryBit) +
        '] "' + FileDisplay(State.Diags[I].FileIdx) + '": Line ' +
        IntToStr(State.Diags[I].Line) + ', Col ' + IntToStr(State.Diags[I].Col) +
        ' - ' + State.Diags[I].Message);
      if State.Diags[I].Snippet <> '' then
        SL.Add('   Offending line:  ' + State.Diags[I].Snippet);
      if State.Diags[I].ExtraLabel <> '' then
        SL.Add('   ' + State.Diags[I].ExtraLabel + ' ' + State.Diags[I].ExtraSnippet);
      if State.Diags[I].LastGoodBlock.Valid then
        SL.Add('   Last good block: "' + FileDisplay(State.Diags[I].LastGoodBlock.FileIdx) +
          '": Line ' + IntToStr(State.Diags[I].LastGoodBlock.Line) + ' (' +
          State.Diags[I].LastGoodBlock.Desc + ') -> ' + State.Diags[I].LastGoodBlock.Snippet);
      if State.Diags[I].LastGoodStmt.Valid then
        SL.Add('   Last good stmt:  "' + FileDisplay(State.Diags[I].LastGoodStmt.FileIdx) +
          '": Line ' + IntToStr(State.Diags[I].LastGoodStmt.Line) + ' (' +
          State.Diags[I].LastGoodStmt.Desc + ') -> ' + State.Diags[I].LastGoodStmt.Snippet);
      SL.Add('');
    end;
    for I := 0 to High(State.Forwards) do
      if State.Forwards[I].RequiresImpl and (State.Forwards[I].ImplFileIdx < 0) then
        SL.Add(GSLocationTag(State.Forwards[I].FileIdx, State.Forwards[I].Line) +
          '[UNIMPL bit=4] Unimplemented declaration in "' +
          FileDisplay(State.Forwards[I].FileIdx) + '": Line ' +
          IntToStr(State.Forwards[I].Line) + ': ' + State.Forwards[I].Signature + ';');
    SL.Add('');
  end
  else
  begin
    SL.Add('No syntax or structural errors detected.');
    SL.Add('');
  end;
end;

AnyPerFile := Options.ReportOpts.ShowFiles or Options.ReportOpts.ShowTypes or
              Options.ReportOpts.ShowGlobals or Options.ReportOpts.ShowForwards or
              Options.ReportOpts.ShowRoutines or Options.ReportOpts.ShowAssigns or
              Options.ReportOpts.ShowCalls or Options.ReportOpts.ShowVars;

if AnyPerFile and (not Options.GiveBlockSpecified) then
begin
  for F := 0 to High(State.Files) do
  begin
    HasContent := Options.ReportOpts.ShowFiles and (Trim(Options.FindPattern) = '');
    if (not HasContent) and Options.ReportOpts.ShowTypes then
      for T := 0 to High(State.Types) do
        if (State.Types[T].FileIdx = F) and StrContainsCI(State.Types[T].Name, Options.FindPattern) and InFindScope(State.Types[T].FileIdx, State.Types[T].StartLine) then
        begin
          HasContent := True;
          Break;
        end;
    if (not HasContent) and Options.ReportOpts.ShowGlobals then
      for G := 0 to High(State.Globals) do
        if (State.Globals[G].FileIdx = F) and StrContainsCI(State.Globals[G].Name, Options.FindPattern) and InFindScope(State.Globals[G].FileIdx, State.Globals[G].Line) then
        begin
          HasContent := True;
          Break;
        end;
    if (not HasContent) and Options.ReportOpts.ShowForwards then
      for P := 0 to High(State.Forwards) do
        if (State.Forwards[P].FileIdx = F) and StrContainsCI(State.Forwards[P].Name, Options.FindPattern) and InFindScope(State.Forwards[P].FileIdx, State.Forwards[P].Line) then
        begin
          HasContent := True;
          Break;
        end;
    if (not HasContent) and (not Options.HideFuncs) and
       (Options.ReportOpts.ShowRoutines or Options.ReportOpts.ShowAssigns or
        Options.ReportOpts.ShowCalls or Options.ReportOpts.ShowVars) then
      for R := 0 to High(State.Routines) do
        if (State.Routines[R].FileIdx = F) and StrContainsCI(State.Routines[R].Name, Options.FindPattern) and InFindScope(State.Routines[R].FileIdx, State.Routines[R].StartLine) then
        begin
          HasContent := True;
          Break;
        end;
    if not HasContent then
      Continue;

    SL.Add('=== File: "' + State.Files[F].DisplayName + '" (' +
      IntToStr(Length(State.Files[F].Lines)) + ' lines) ===');

    if Options.ReportOpts.ShowFiles and (Trim(Options.FindPattern) = '') then
    begin
      if State.Files[F].IncludedFromFile >= 0 then
        SL.Add('  From "' + FileDisplay(State.Files[F].IncludedFromFile) +
          '": Line ' + IntToStr(State.Files[F].IncludedFromLine) + ';');
      HdrPrinted := False;
      for I := 0 to High(State.TreeEdges) do
        if State.TreeEdges[I].ParentFileIdx = F then
        begin
          if not HdrPrinted then
          begin
            SL.Add('  Includes:');
            HdrPrinted := True;
          end;
          SL.Add('    Line ' + IntToStr(State.TreeEdges[I].ParentLine) + ': ' +
            State.TreeEdges[I].EdgeKind + ' ' + State.TreeEdges[I].TargetDisplay + ';');
        end;
    end;

    if Options.ReportOpts.ShowTypes then
    begin
      HdrPrinted := False;
      for T := 0 to High(State.Types) do
      begin
        if (State.Types[T].FileIdx <> F) or (not StrContainsCI(State.Types[T].Name, Options.FindPattern)) or (not InFindScope(State.Types[T].FileIdx, State.Types[T].StartLine)) then
          Continue;
        if not HdrPrinted then
        begin
          SL.Add('  [Types]');
          HdrPrinted := True;
        end;
        if State.Types[T].IsForward then
          SL.Add('    Line ' + IntToStr(State.Types[T].StartLine) + ': ' +
            State.Types[T].Name + ' = ' + State.Types[T].Kind + ' (forward);')
        else if (Length(State.Types[T].Fields) = 0) and (Length(State.Types[T].Methods) = 0) then
          SL.Add('    Line ' + IntToStr(State.Types[T].StartLine) + ': ' +
            State.Types[T].Name + ' = ' + State.Types[T].Kind + ';')
        else
        begin
          SL.Add('    Line ' + IntToStr(State.Types[T].StartLine) + ': ' +
            State.Types[T].Name + ' = ' + State.Types[T].Kind + ' - Start: Line ' +
            IntToStr(State.Types[T].StartLine) + ', End: Line ' + IntToStr(State.Types[T].EndLine) + ';');
          if Length(State.Types[T].Fields) > 0 then
          begin
            SL.Add('      fields:');
            for K := 0 to High(State.Types[T].Fields) do
              SL.Add('        Line ' + IntToStr(State.Types[T].Fields[K].Line) + ': ' +
                State.Types[T].Fields[K].Name + ':' + State.Types[T].Fields[K].Detail + ';');
          end;
          if Length(State.Types[T].Methods) > 0 then
          begin
            SL.Add('      methods:');
            for K := 0 to High(State.Types[T].Methods) do
              SL.Add('        Line ' + IntToStr(State.Types[T].Methods[K].Line) + ': ' +
                State.Types[T].Methods[K].Detail + ';');
          end;
        end;
      end;
    end;

    if Options.ReportOpts.ShowGlobals then
    begin
      HdrPrinted := False;
      for G := 0 to High(State.Globals) do
      begin
        if (State.Globals[G].FileIdx <> F) or (not StrContainsCI(State.Globals[G].Name, Options.FindPattern)) or (not InFindScope(State.Globals[G].FileIdx, State.Globals[G].Line)) then
          Continue;
        if not HdrPrinted then
        begin
          SL.Add('  [Globals / Constants]');
          HdrPrinted := True;
        end;
        if State.Globals[G].IsConst then
          SL.Add('    Line ' + IntToStr(State.Globals[G].Line) + ': const ' +
            State.Globals[G].Name + ':' + State.Globals[G].Detail + ';')
        else
          SL.Add('    Line ' + IntToStr(State.Globals[G].Line) + ': var ' +
            State.Globals[G].Name + ':' + State.Globals[G].Detail + ';');
      end;
    end;

    if Options.ReportOpts.ShowForwards then
    begin
      HdrPrinted := False;
      for P := 0 to High(State.Forwards) do
      begin
        if (State.Forwards[P].FileIdx <> F) or (not StrContainsCI(State.Forwards[P].Name, Options.FindPattern)) or (not InFindScope(State.Forwards[P].FileIdx, State.Forwards[P].Line)) then
          Continue;
        if not HdrPrinted then
        begin
          SL.Add('  [Interface / Forward Declarations]');
          HdrPrinted := True;
        end;
        SigStr := '    Line ' + IntToStr(State.Forwards[P].Line) + ': ' + State.Forwards[P].Signature;
        if State.Forwards[P].ImplFileIdx >= 0 then
          SigStr := SigStr + ' -> Implemented at "' +
            FileDisplay(State.Forwards[P].ImplFileIdx) + '": Line ' +
            IntToStr(State.Forwards[P].ImplLine) + ';'
        else if State.Forwards[P].RequiresImpl then
          SigStr := SigStr + ' -> (UNIMPLEMENTED);'
        else
          SigStr := SigStr + ' -> (external);';
        SL.Add(SigStr);
      end;
    end;

    if (not Options.HideFuncs) and
       (Options.ReportOpts.ShowRoutines or Options.ReportOpts.ShowAssigns or
        Options.ReportOpts.ShowCalls or Options.ReportOpts.ShowVars) then
    begin
      HdrPrinted := False;
      for R := 0 to High(State.Routines) do
      begin
        if (State.Routines[R].FileIdx <> F) or (not StrContainsCI(State.Routines[R].Name, Options.FindPattern)) or (not InFindScope(State.Routines[R].FileIdx, State.Routines[R].StartLine)) then
          Continue;
        if not HdrPrinted then
        begin
          SL.Add('  [Routines]');
          HdrPrinted := True;
        end;
        SigStr := '    Line ' + IntToStr(State.Routines[R].StartLine) + ': ' +
          State.Routines[R].Kind + ' ' + State.Routines[R].Name + '(';
        for K := 0 to High(State.Routines[R].Params) do
        begin
          if K > 0 then SigStr := SigStr + '; ';
          SigStr := SigStr + State.Routines[R].Params[K].Name + ':' + State.Routines[R].Params[K].Detail;
        end;
        SigStr := SigStr + ')';
        if State.Routines[R].ReturnType <> '' then
          SigStr := SigStr + ':' + State.Routines[R].ReturnType;
        SigStr := SigStr + ' - Start: Line ' + IntToStr(State.Routines[R].StartLine) +
          ', End: Line ' + IntToStr(State.Routines[R].EndLine) + ';';
        SL.Add(SigStr);

        if Options.ReportOpts.ShowRoutines then
        begin
          if Length(State.Routines[R].Includes) > 0 then
          begin
            SL.Add('      includes:');
            EmitUsageListText(SL, State.Routines[R].Includes, F, '        ');
          end;
          if (not Options.HideVars) and (Length(State.Routines[R].Params) > 0) then
          begin
            SL.Add('      params:');
            EmitUsageListText(SL, State.Routines[R].Params, F, '        ');
          end;
          if (not Options.HideVars) and (Length(State.Routines[R].Locals) > 0) then
          begin
            SL.Add('      locals:');
            EmitUsageListText(SL, State.Routines[R].Locals, F, '        ');
          end;
        end;

        if Options.ReportOpts.ShowAssigns and (Length(State.Routines[R].Assigns) > 0) then
        begin
          SL.Add('      assigns:');
          EmitUsageListText(SL, State.Routines[R].Assigns, F, '        ');
        end;

        if Options.ReportOpts.ShowCalls then
        begin
          if Length(State.Routines[R].Calls) = 0 then
            SL.Add('      calls: (none)')
          else
          begin
            SL.Add('      calls:');
            EmitUsageListText(SL, State.Routines[R].Calls, F, '        ');
          end;
        end;

        if Options.ReportOpts.ShowVars and (not Options.HideVars) then
        begin
          if Length(State.Routines[R].Vars) = 0 then
            SL.Add('      vars: (none)')
          else
          begin
            SL.Add('      vars:');
            EmitUsageListText(SL, State.Routines[R].Vars, F, '        ');
          end;
        end;

        if (Trim(Options.ShowRoutineTarget) <> '') and StrContainsCI(State.Routines[R].Name, Options.ShowRoutineTarget) then
          EmitSourceSliceText(SL, F, State.Routines[R].StartLine, State.Routines[R].EndLine, '      ');
      end;
    end;
    SL.Add('');
  end;
end;

Result := SL.Text;


finally
SL.Free;
end;
end;

{ ============================================================================
CLI Option Parsing & Entrypoint
============================================================================ }

procedure SetAllReportSections(var Opts: TReportSections; Enabled: Boolean);
begin
Opts.ShowTree := Enabled;
Opts.ShowBlockTree := Enabled;
Opts.ShowDiag := Enabled;
Opts.ShowFiles := Enabled;
Opts.ShowTypes := Enabled;
Opts.ShowGlobals := Enabled;
Opts.ShowForwards := Enabled;
Opts.ShowRoutines := Enabled;
Opts.ShowAssigns := Enabled;
Opts.ShowCalls := Enabled;
Opts.ShowVars := Enabled;
end;

function ParseReportFilter(const Spec: string; var Opts: TReportSections;
out BadToken: string): Boolean;
var
P, NextSep: Integer;
Item: string;
begin
Result := True;
BadToken := '';
if not Options.ReportFilterSet then
begin
SetAllReportSections(Opts, False);
ReportFilterSet := True;
end;

P := 1;
while P <= Length(Spec) do
begin
while (P <= Length(Spec)) and (Spec[P] in [':', ',', ' ', #9]) do
Inc(P);
if P > Length(Spec) then
Break;
NextSep := P;
while (NextSep <= Length(Spec)) and not (Spec[NextSep] in [':', ',']) do
Inc(NextSep);
Item := LowerCase(Trim(Copy(Spec, P, NextSep - P)));
P := NextSep + 1;

if Item = 'all' then
  SetAllReportSections(Opts, True)
else if (Item = 'tree') or (Item = 'include-tree') then
  Opts.ShowTree := True
else if (Item = 'block-tree') or (Item = 'logic-tree') then
  Opts.ShowBlockTree := True
else if (Item = 'diag') or (Item = 'diagnostics') or (Item = 'errors') then
  Opts.ShowDiag := True
else if (Item = 'files') or (Item = 'includes') then
  Opts.ShowFiles := True
else if (Item = 'type') or (Item = 'types') then
  Opts.ShowTypes := True
else if (Item = 'global') or (Item = 'globals') or (Item = 'consts') then
  Opts.ShowGlobals := True
else if (Item = 'forward') or (Item = 'forwards') or (Item = 'interface') then
  Opts.ShowForwards := True
else if (Item = 'routine') or (Item = 'routines') or (Item = 'funcs') then
  Opts.ShowRoutines := True
else if (Item = 'assign') or (Item = 'assigns') then
begin
  Opts.ShowRoutines := True;
  Opts.ShowAssigns := True;
end
else if (Item = 'call') or (Item = 'calls') or (Item = 'typecasts') then
begin
  Opts.ShowRoutines := True;
  Opts.ShowCalls := True;
end
else if (Item = 'var') or (Item = 'vars') or (Item = 'variables') then
begin
  Opts.ShowRoutines := True;
  Opts.ShowVars := True;
end
else
begin
  BadToken := Item;
  Exit(False);
end;


end;
end;

procedure PrintHelp(var F: Text);
begin
  WriteLn(F, 'fpctools ', FPCAUDIT_VERSION, ' (parser ', FPCAUDIT_PARSER_VERSION, ') - FreePascal / Object Pascal Auditor');
  WriteLn(F, '');
  WriteLn(F, 'USAGE:');
  WriteLn(F, '  fpctools [command] [--flags] <source_file.pas>');
  WriteLn(F, '  Convention: commands (root actions) use - or / (e.g. -check, /delete).');
  WriteLn(F, '             flags (modifiers) use -- (e.g. --diff, --strict, --json).');
  WriteLn(F, '  Legacy --command forms are accepted for compatibility.');
  WriteLn(F, '');
  WriteLn(F, 'INFORMATION COMMANDS:');
  WriteLn(F, '  -h, --help, -?, /?       Display this help text and exit');
  WriteLn(F, '  -version                 Print version and exit');
  WriteLn(F, '  -schema-version          Print JSON schema version and exit');
  WriteLn(F, '');
  WriteLn(F, 'REPORT / QUERY COMMANDS:');
  WriteLn(F, '  -check                   Diagnostics-only check with bitmask exit code');
  WriteLn(F, '  Note: stmt edits support --diff (preview), --dry-run (no write), --verify (parse-check).');
  WriteLn(F, '        Use -stmts first to get statement indices, then edit by index.');
  WriteLn(F, '        Indices are 1-based, in source order, covering block body (unwrapped).');
  WriteLn(F, '        Drill-down: Foo/3 lists statements inside statement 3 of Foo.');
  WriteLn(F, '                    Foo/3/2 edits statement 2 inside statement 3 of Foo.');
  WriteLn(F, '        Supports begin..end and if/for/while/repeat/case/with bodies.');
  WriteLn(F, '        IMPORTANT: prefer GSLine paths (see -gsline) for statement edits — line numbers');
  WriteLn(F, '        shift after every write; -glines/-gline are deprecated. Convert compiler line');
  WriteLn(F, '        numbers with -gline-to-gsline <n>.');
  WriteLn(F, '');


  WriteLn(F, '  -edit-gline <n>          DEPRECATED: replace global line n (use -gsline)');
  WriteLn(F, '  -delete-gline <n>        DEPRECATED: delete global line n (use -gsline)');
  WriteLn(F, '  -filter <symbol>         Show only matching symbols with their enclosing block chain');
  WriteLn(F, '  -find <q>                Filter symbols or locate block ("fn:var", "#12")');
  WriteLn(F, '  -callers <name>          Show routines calling <name>');
  WriteLn(F, '  -orphans                 List routines potentially unreachable from entry points');
  WriteLn(F, '  -show <name>             Show routine details + numbered source lines');
  WriteLn(F, '  -lines <file:a-b>        Print numbered source lines from a file');
  WriteLn(F, '  -search <pattern>        Pascal token match (ignores whitespace/comments/case)');
  WriteLn(F, '  -read-full <mode> <line> Read full statement/block/line at a line number');
  WriteLn(F, '  -edit-plan <query>       Resolve a block and print an edit plan preview');
  WriteLn(F, '  -gsline [selector]       List GS statements: none=all, a-b=range, GS# or path=one');
  WriteLn(F, '  -gslines <a-b>           Alias for -gsline <a-b> (compatibility)');
  WriteLn(F, '  -decode-gsline <n>       Print the block/statement edit path for GSLine n');
  WriteLn(F, '  -gline-to-gsline <n>     List GSLine(s) covering global line n (alias -gline2gs)');
  WriteLn(F, '  Note: GSLine numbers full statements across all connected files; a physical');
  WriteLn(F, '        line holding several statements shows ordinals like "L 88.1", "L 88.2".');
  WriteLn(F, '        Statement edits also accept GS<n> as their target.');
  WriteLn(F, '');
  WriteLn(F, 'EDIT COMMANDS:');
  WriteLn(F, '  -insert <target> <text>       Insert inline text at <target> (before that line)');
  WriteLn(F, '  -insert-before <target> <text>  Insert inline text before <target>');
  WriteLn(F, '  -insert-after <target> <text>   Insert inline text after <target>');
  WriteLn(F, '  -insert-file <target> <path>    Insert file contents at <target> (before that line)');
  WriteLn(F, '  -insert-file-before <target> <path>  Insert file contents before <target>');
  WriteLn(F, '  -insert-file-after <target> <path>   Insert file contents after <target>');
  WriteLn(F, '  Note: <target> is a line number, ''start-end'' range, ''#id'', or a block/symbol');
  WriteLn(F, '        name (e.g. a routine). The -insert* forms take literal TEXT as the last');
  WriteLn(F, '        argument; the -insert-file* forms take a FILE PATH as the last argument.');
  WriteLn(F, '        --before/--after may be used with -insert/-insert-file instead of the');
  WriteLn(F, '        dedicated forms (e.g. -insert-file --after P snippet.txt).');
  WriteLn(F, '  -replace <target> <text> Replace a block with text');
  WriteLn(F, '  -replace-file <t> <path> Replace a block with file contents');
  WriteLn(F, '  -delete <target>         Delete a block (#id, start-end, or symbol)');
  WriteLn(F, '  -edit-block <target>     Edit by fragment inside a block (needs --match/--with)');
  WriteLn(F, '  -edit-global             Edit a unique fragment across all connected files');
  WriteLn(F, '  Editing without line numbers: locate with -gsline / -find / -block-tree;');
  WriteLn(F, '    whole statement -> -stmt-replace <path> ...; part of a line -> -replace-fragment;');
  WriteLn(F, '    whole line -> -edit-block ... --match ... --with ...; NEVER grep for line numbers.');
  WriteLn(F, '  -replace-fragment <block> <fragment> <text>  Replace only the matched token (keeps rest of line)');
  WriteLn(F, '  -delete-global           Delete a unique fragment across all connected files');
  WriteLn(F, '');
  WriteLn(F, 'STATEMENT COMMANDS:');
  WriteLn(F, '  -stmts <target>          List top-level statements inside a block target');
  WriteLn(F, '  -stmt-replace <t> <i> <s> Replace statement index i in block t with s');
  WriteLn(F, '  -stmt-delete <t> <i>     Delete statement index i in block t');
  WriteLn(F, '  -stmt-insert-before <t> <i> <s> Insert text s before statement i in block t');
  WriteLn(F, '  -stmt-insert-after <t> <i> <s>  Insert text s after statement i in block t');
  WriteLn(F, '  Note: stmt edits support --diff (preview), --dry-run (no write), --verify (parse-check).');
  WriteLn(F, '        Use -stmts first to get statement indices, then edit by index.');
  WriteLn(F, '        Indices are 1-based, in source order, covering block body (unwrapped).');
  WriteLn(F, '');


  WriteLn(F, 'FORWARD COMMANDS:');
  WriteLn(F, '  -check-forward           Report forwards: used/unused/needs/ambiguous/errors');
  WriteLn(F, '  -fix-forward             Check and fix all forward declarations');
  WriteLn(F, '  -fix-all                 Apply all unambiguous fixes (currently: forwards)');
  WriteLn(F, '');
  WriteLn(F, 'FLAGS (modifiers):');
  WriteLn(F, '  --strict                 Strict checks: unresolved calls, heuristic includes');
  WriteLn(F, '  --json, --format:json    Emit structured JSON output');
  WriteLn(F, '  --format:sarif           Emit SARIF 2.1.0 output');
  WriteLn(F, '  --report=<sections>      Emit only selected sections (tree,block-tree,diag,files,');
  WriteLn(F, '                           types,globals,forwards,routines,assigns,calls,vars,all)');
  WriteLn(F, '  --diff                   Show unified diff of pending edit (no file change)');
  WriteLn(F, '  --dry-run                Show what would change/fix without applying');
  WriteLn(F, '  --verify                 Parse result before applying; revert on error');
  WriteLn(F, '  --before <target>        Modifier: place insert before a block target');
  WriteLn(F, '  --after <target>         Modifier: place insert after a block target');
  WriteLn(F, '  --add-forward            Auto-add forwards when doing -insert/-replace');
  WriteLn(F, '  --add-include            With -read-full: inline included files');
  WriteLn(F, '  --add-block              With -read-full: expand to full enclosing block');
  WriteLn(F, '  --outinsert <file>       Write edit result to <file> instead of in place');
  WriteLn(F, '  --output-raw             For -edit-plan: emit only raw block source');
  WriteLn(F, '  --give-block <N>         Return chunk N of the block matched by -find');
  WriteLn(F, '  --block-size <N>         Max lines per code chunk (default: 128)');
  WriteLn(F, '  --widen [N]              Go back N enclosing blocks (aliases: --back-block, --parent-block)');
  WriteLn(F, '  --in <target>            Scope queries and -delete/-replace to a container');
  WriteLn(F, '  --match <fragment>       With -edit-block: unique token fragment to replace');
  WriteLn(F, '  --with <text>            With -edit-block: replacement text (\n = newline)');
  WriteLn(F, '  --with-origin            With -get-block: stamp each block with its source origin');
  WriteLn(F, '  --standalone             With -get-block: wrap selected blocks in a compilable program');
  WriteLn(F, '  --max-depth <N>          Limit -block-tree nesting depth');
  WriteLn(F, '  --no-vars/--no-funcs/--no-blocks/--no-assigns/--no-calls/--no-types/');
  WriteLn(F, '  --no-globals/--no-forwards/--no-files/--no-tree/--no-block-tree/--no-diag');
  WriteLn(F, '  -Fi<path>                Add path to {$I}/{$INCLUDE} search paths');
  WriteLn(F, '  -Fu<path>                Add unit search path and enable unit resolution');
  WriteLn(F, '  --units                  Resolve uses-clause units (source dir + cwd)');
  WriteLn(F, '  --lazarus <project>      Load include paths from a Lazarus project (.lpi/.lpr)');
  WriteLn(F, '  --no-cache               Do not read or write .fpaudit.cache');
  WriteLn(F, '  --clear-cache            Rebuild .fpaudit.cache from scratch');
  WriteLn(F, '');
  WriteLn(F, 'BITMASK EXIT CODES:');
  WriteLn(F, '  0=clean, 1=syntax, 2=structural, 4=unimplemented decls, 8=include errors, 16=warnings');
end;

function TryParseCliValueOpt(const Param, OptName: string;
  var ArgIdx: Integer; var OutVal: string): Boolean;

  function OptSuffix(const N: string): string;
  begin
    if (Length(N) >= 2) and (N[1] = '-') and (N[2] = '-') then
      Result := Copy(N, 3, MaxInt)
    else if (Length(N) >= 1) and ((N[1] = '-') or (N[1] = '/')) then
      Result := Copy(N, 2, MaxInt)
    else
      Result := N;
  end;

  function MatchesName(const P, N: string): Boolean;
  var Suf: string;
  begin
    if P = N then Exit(True);
    Suf := OptSuffix(N);
    Result := (P = '--' + Suf) or (P = '-' + Suf) or (P = '/' + Suf);
  end;

  function PrefixMatch(const P, N: string; out Val: string): Boolean;
  var Suf, Pre1, Pre2, Pre3: string;
  begin
    Result := False; Val := '';
    Suf := OptSuffix(N);
    Pre1 := '--' + Suf + '=';
    Pre2 := '-' + Suf + '=';
    Pre3 := '/' + Suf + '=';
    if Copy(P, 1, Length(Pre1)) = Pre1 then begin Val := Copy(P, Length(Pre1)+1, MaxInt); Exit(True); end;
    if Copy(P, 1, Length(Pre2)) = Pre2 then begin Val := Copy(P, Length(Pre2)+1, MaxInt); Exit(True); end;
    if Copy(P, 1, Length(Pre3)) = Pre3 then begin Val := Copy(P, Length(Pre3)+1, MaxInt); Exit(True); end;
  end;


var V: string;
begin
  Result := False;
  if MatchesName(Param, OptName) then
  begin
    if ArgIdx + 1 <= ParamCount then
    begin
      Inc(ArgIdx);
      OutVal := ParamStr(ArgIdx);
      Exit(True);
    end;
    WriteLn(ErrOutput, 'Missing value for option: ', OptName);
    Halt(1);
  end;
  if PrefixMatch(Param, OptName, V) then
  begin
    OutVal := V;
    Exit(True);
  end;
end;
function IsCmd(const Param, Name: string): Boolean;
var N: string;
begin
  N := LowerCase(Name);
  if (Length(N) >= 2) and (N[1] = '-') and (N[2] = '-') then N := Copy(N, 3, MaxInt)
  else if (Length(N) >= 1) and ((N[1] = '-') or (N[1] = '/')) then N := Copy(N, 2, MaxInt);
  Result := (Param = '--' + N) or (Param = '-' + N) or (Param = '/' + N);
end;



{ Extract routine name from a Pascal function/procedure signature line }
function ExtractRoutineName(const Line: string): string;
var
  S: string;
  P: Integer;
begin
  Result := '';
  S := Trim(Line);
  if (Copy(S, 1, 8) = 'function') then
    S := Trim(Copy(S, 9, MaxInt))
  else if (Copy(S, 1, 9) = 'procedure') then
    S := Trim(Copy(S, 10, MaxInt))
  else
    Exit;
  P := 1;
  while (P <= Length(S)) and (S[P] in ['A'..'Z','a'..'z','0'..'9','_','.']) do
    Inc(P);
  Result := Copy(S, 1, P - 1);
end;

{ Extract full signature (without 'forward;') from a routine declaration line }
function ExtractRoutineSignature(const Line: string): string;
var
  S: string;
  P: Integer;
begin
  S := Trim(Line);
  P := Pos('forward;', LowerCase(S));
  if P > 0 then
    S := Trim(Copy(S, 1, P - 1));
  Result := S;
end;

{ Scan root file for forward declarations }
function ScanForwardDecls(FIdx: Integer): TForwardInfoArray;
var
  I: Integer;
  L: string;
begin
  Result := nil;
  if (FIdx < 0) or (FIdx >= Length(State.Files)) then Exit;
  for I := 0 to High(State.Files[FIdx].Lines) do
  begin
    L := Trim(State.Files[FIdx].Lines[I]);
    if (Copy(L, 1, 8) = 'function') or (Copy(L, 1, 9) = 'procedure') then
      if Pos('forward;', LowerCase(L)) > 0 then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)].Name := ExtractRoutineName(L);
        Result[High(Result)].Signature := ExtractRoutineSignature(L);
        Result[High(Result)].LineNum := I + 1;
        Result[High(Result)].HasImpl := False;
        Result[High(Result)].ImplLine := 0;
        Result[High(Result)].ImplSignature := '';
        Result[High(Result)].ImpCount := 0;
      end;
  end;
end;

{ Scan root file for implementations (not forward) }
function ScanImplementations(FIdx: Integer): TImplInfoArray;
var
  I: Integer;
  L: string;
begin
  Result := nil;
  if (FIdx < 0) or (FIdx >= Length(State.Files)) then Exit;
  for I := 0 to High(State.Files[FIdx].Lines) do
  begin
    L := Trim(State.Files[FIdx].Lines[I]);
    if (Copy(L, 1, 8) = 'function') or (Copy(L, 1, 9) = 'procedure') then
      if Pos('forward;', LowerCase(L)) = 0 then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)].Name := ExtractRoutineName(L);
        Result[High(Result)].Signature := ExtractRoutineSignature(L);
        Result[High(Result)].LineNum := I + 1;
        Result[High(Result)].HasForward := False;
      end;
  end;
end;

{ Compare forwards with implementations; return match status }
{ Normalized parameter key: lowercase, no spaces, between first '(' and matching ')' }
function ExtractParamKey(const Sig: string): string;
var
  I, Depth: Integer;
  InStr: Boolean;
  C: Char;
begin
  Result := '';
  InStr := False;
  Depth := 0;
  for I := 1 to Length(Sig) do
  begin
    C := Sig[I];
    if InStr then
    begin
      if C = '''' then InStr := False;
      Result := Result + LowerCase(C);
      Continue;
    end;
    if C = '''' then
    begin
      InStr := True;
      Result := Result + LowerCase(C);
      Continue;
    end;
    if C = '(' then
    begin
      Inc(Depth);
      if Depth = 1 then Continue;
    end
    else if C = ')' then
    begin
      Dec(Depth);
      if Depth = 0 then Break;
    end;
    if (Depth >= 1) and (C <= ' ') then Continue;
    if Depth >= 1 then
      Result := Result + LowerCase(C);
  end;
end;

procedure MatchForwards(var Fwds: TForwardInfoArray; var Impls: TImplInfoArray);
var
  I, J: Integer;
  FK, IK: string;
begin
  for I := 0 to High(Fwds) do
  begin
    Fwds[I].ImpCount := 0;
    Fwds[I].HasImpl := False;
    Fwds[I].ImplLine := 0;
    Fwds[I].ImplSignature := '';
    FK := ExtractParamKey(Fwds[I].Signature);
    for J := 0 to High(Impls) do
    begin
      if not SameText(Fwds[I].Name, Impls[J].Name) then Continue;
      IK := ExtractParamKey(Impls[J].Signature);
      if FK <> IK then Continue;
      Inc(Fwds[I].ImpCount);
      Fwds[I].HasImpl := True;
      Fwds[I].ImplLine := Impls[J].LineNum;
      Fwds[I].ImplSignature := Impls[J].Signature;
      Impls[J].HasForward := True;
    end;
  end;
  for J := 0 to High(Impls) do
  begin
    Impls[J].HasForward := False;
    IK := ExtractParamKey(Impls[J].Signature);
    for I := 0 to High(Fwds) do
    begin
      if not SameText(Fwds[I].Name, Impls[J].Name) then Continue;
      if ExtractParamKey(Fwds[I].Signature) <> IK then Continue;
      Impls[J].HasForward := True;
      Break;
    end;
  end;
end;


{ Emit a unified diff between two line arrays }
procedure EmitUnifiedDiff(const A, B: TStringArray; const FName: string);
var
  P, SA, SB, I: Integer;
  OldStart, OldCount, NewStart, NewCount: Integer;
begin
  { common prefix }
  P := 0;
  while (P < Length(A)) and (P < Length(B)) and (A[P] = B[P]) do Inc(P);
  { common suffix }
  SA := Length(A) - 1;
  SB := Length(B) - 1;
  while (SA >= P) and (SB >= P) and (A[SA] = B[SB]) do
  begin
    Dec(SA);
    Dec(SB);
  end;

  WriteLn(Output, '--- ', FName);
  WriteLn(Output, '+++ ', FName);

  OldStart := P - 3 + 1;
  if OldStart < 1 then OldStart := 1;
  NewStart := OldStart;
  OldCount := (SA - P + 1) + 6;
  NewCount := (SB - P + 1) + 6;
  if OldCount < 1 then OldCount := 1;
  if NewCount < 1 then NewCount := 1;
  WriteLn(Output, Format('@@ -%d,%d +%d,%d @@', [OldStart, OldCount, NewStart, NewCount]));

  { context before: up to 3 lines before P (0-based indices P-3..P-1) }
  I := P - 3;
  if I < 0 then I := 0;
  while I < P do
  begin
    WriteLn(Output, ' ' + A[I]);
    Inc(I);
  end;

  { removed lines: A[P..SA] }
  for I := P to SA do
    WriteLn(Output, '-' + A[I]);

  { added lines: B[P..SB] }
  for I := P to SB do
    WriteLn(Output, '+' + B[I]);

  { context after: up to 3 lines after SA (0-based SA+1..SA+3) }
  I := SA + 1;
  while (I <= Length(A) - 1) and (I <= SA + 3) do
  begin
    WriteLn(Output, ' ' + A[I]);
    Inc(I);
  end;
end;
{ Build a minimal SARIF 2.1.0 report from diagnostics }
function BuildSarifReport(ExitCode: Integer): string;
var
  SL: TStringList;
  I: Integer;
  Lvl: string;
begin
  SL := TStringList.Create;
  try
    SL.Add('{');
    SL.Add('  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",');
    SL.Add('  "version": "2.1.0",');
    SL.Add('  "runs": [{');
    SL.Add('    "tool": { "driver": { "name": "fpctools", "version": "' + FPCAUDIT_VERSION + '" } },');
    SL.Add('    "results": [');
    for I := 0 to High(State.Diags) do
    begin
      case State.Diags[I].CategoryBit of
        EXIT_BIT_WARNING: Lvl := 'warning';
        EXIT_BIT_SYNTAX: Lvl := 'error';
      else
        Lvl := 'error';
      end;
      if I > 0 then SL.Add(',');
      SL.Add('      {');
      SL.Add('        "ruleId": "FPC" + IntToStr(State.Diags[I].CategoryBit) + '',');
      SL.Add('        "level": "' + Lvl + '",');
      SL.Add('        "message": { "text": "' + JsonEscape(State.Diags[I].Message) + '" },');
      SL.Add('        "locations": [{ "physicalLocation": {');
      SL.Add('          "artifactLocation": { "uri": "' + JsonEscape(FileDisplay(State.Diags[I].FileIdx)) + '" },');
      SL.Add('          "region": { "startLine": ' + IntToStr(State.Diags[I].Line) +
        ', "startColumn": ' + IntToStr(State.Diags[I].Col) + ' }');
      SL.Add('        } }]');
      SL.Add('      }');
    end;
    SL.Add('    ]');
    SL.Add('  }]');
    SL.Add('}');
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;
{ Resolve an edit target (#id, symbol, line N, or line range N-M) to a 1-based line range.
  AfterMode shifts an insert point to just after the target. }
{ Build a new line array by removing a line range and optionally inserting replacement text }
function BuildEditedLines(const Lines: TStringArray; StartLn, EndLn: Integer;
  RemoveRange, DoReplace: Boolean; const ReplaceText: string): TStringArray;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(Lines) do
  begin
    if RemoveRange and (I + 1 >= StartLn) and (I + 1 <= EndLn) then
    begin
      if DoReplace and (I + 1 = StartLn) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := ReplaceText;
      end;
      Continue;
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Lines[I];
  end;
end;
{ Emit block chain (innermost -> outermost) to a string list }
procedure EmitBlockChainToStrings(SL: TStringList; BlkIdx: Integer);
var
  Cur: Integer;
begin
  Cur := BlkIdx;
  while Cur >= 0 do
  begin
    SL.Add('    [' + LogicBlockTypeTag(State.LogicBlocks[Cur].Kind) + ' #' + IntToStr(State.LogicBlocks[Cur].Id) + '] ' +
      State.LogicBlocks[Cur].LabelText);
    Cur := State.LogicBlocks[Cur].ParentIdx;
  end;
end;

{ Find the innermost logic block containing a given line in a file }
function FindBlockAtLine(FIdx, LineNum: Integer): Integer;
var
  I, Best, Span: Integer;
begin
  Result := -1;
  Best := MaxInt;
  for I := 0 to High(State.LogicBlocks) do
    if (State.LogicBlocks[I].FileIdx = FIdx) and
       (LineNum >= State.LogicBlocks[I].StartLine) and
       (LineNum <= State.LogicBlocks[I].EndLine) then
    begin
      Span := State.LogicBlocks[I].EndLine - State.LogicBlocks[I].StartLine + 1;
      if Span < Best then
      begin
        Best := Span;
        Result := I;
      end;
    end;
end;


{ Build a filtered report: show only symbols/variables matching FilterPattern,
  each with its enclosing block chain. }
function BuildFilterReport: string;
var
  SL: TStringList;
  I, J, BlkIdx: Integer;
  Found: Boolean;
begin
  SL := TStringList.Create;
  try
    SL.Add('=== FILTERED SYMBOL REPORT: "' + Options.FilterPattern + '" ===');
    if Trim(Options.SearchInTarget) <> '' then
      SL.Add('scope: ' + Options.SearchInTarget);
    SL.Add('');
    Found := False;

    { globals }
    for I := 0 to High(State.Globals) do
      if StrContainsCI(State.Globals[I].Name, Options.FilterPattern) and InFindScope(State.Globals[I].FileIdx, State.Globals[I].Line) then
      begin
        Found := True;
        SL.Add('GLOBAL: ' + State.Globals[I].Name + ':' + State.Globals[I].Detail);
        BlkIdx := FindBlockAtLine(State.Globals[I].FileIdx, State.Globals[I].Line);
        if BlkIdx >= 0 then EmitBlockChainToStrings(SL, BlkIdx);
      end;

    { routines }
    for I := 0 to High(State.Routines) do
      if StrContainsCI(State.Routines[I].Name, Options.FilterPattern) and InFindScope(State.Routines[I].FileIdx, State.Routines[I].StartLine) then
      begin
        Found := True;
        SL.Add('ROUTINE: ' + State.Routines[I].Name);
        BlkIdx := State.Routines[I].RootBlockIdx;
        if BlkIdx >= 0 then EmitBlockChainToStrings(SL, BlkIdx);
      end;

    { types }
    for I := 0 to High(State.Types) do
      if StrContainsCI(State.Types[I].Name, Options.FilterPattern) and InFindScope(State.Types[I].FileIdx, State.Types[I].StartLine) then
      begin
        Found := True;
        SL.Add('TYPE: ' + State.Types[I].Name);
        BlkIdx := FindBlockAtLine(State.Types[I].FileIdx, State.Types[I].StartLine);
        if BlkIdx >= 0 then EmitBlockChainToStrings(SL, BlkIdx);
      end;

    { forwards }
    for I := 0 to High(State.Forwards) do
      if StrContainsCI(State.Forwards[I].Name, Options.FilterPattern) and InFindScope(State.Forwards[I].FileIdx, State.Forwards[I].Line) then
      begin
        Found := True;
        SL.Add('FORWARD: ' + State.Forwards[I].Name);
        BlkIdx := FindBlockAtLine(State.Forwards[I].FileIdx, State.Forwards[I].Line);
        if BlkIdx >= 0 then EmitBlockChainToStrings(SL, BlkIdx);
      end;

    { routine locals / params / vars }
    for I := 0 to High(State.Routines) do
    begin
      for J := 0 to High(State.Routines[I].Locals) do
        if StrContainsCI(State.Routines[I].Locals[J].Name, Options.FilterPattern) and InFindScope(State.Routines[I].FileIdx, State.Routines[I].StartLine) then
        begin
          Found := True;
          SL.Add('LOCAL: ' + State.Routines[I].Locals[J].Name + ' (in ' + State.Routines[I].Name + ')');
          BlkIdx := State.Routines[I].RootBlockIdx;
          if BlkIdx >= 0 then EmitBlockChainToStrings(SL, BlkIdx);
        end;
      for J := 0 to High(State.Routines[I].Params) do
        if StrContainsCI(State.Routines[I].Params[J].Name, Options.FilterPattern) and InFindScope(State.Routines[I].FileIdx, State.Routines[I].StartLine) then
        begin
          Found := True;
          SL.Add('PARAM: ' + State.Routines[I].Params[J].Name + ' (in ' + State.Routines[I].Name + ')');
          BlkIdx := State.Routines[I].RootBlockIdx;
          if BlkIdx >= 0 then EmitBlockChainToStrings(SL, BlkIdx);
        end;
      for J := 0 to High(State.Routines[I].Vars) do
        if StrContainsCI(State.Routines[I].Vars[J].Name, Options.FilterPattern) and InFindScope(State.Routines[I].FileIdx, State.Routines[I].StartLine) then
        begin
          Found := True;
          SL.Add('VAR: ' + State.Routines[I].Vars[J].Name + ' (in ' + State.Routines[I].Name + ')');
          BlkIdx := State.Routines[I].RootBlockIdx;
          if BlkIdx >= 0 then EmitBlockChainToStrings(SL, BlkIdx);
        end;
    end;

    if not Found then
      SL.Add('  No symbols matched "' + Options.FilterPattern + '"');
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;
{ Expand a target line to full statement boundaries using the token stream.
  Walks back over if/while/for/case prefixes and forward over begin/end blocks. }
{ Return True if a line contains only a comment (no code tokens) in a file }
function IsCommentOnlyLine(FIdx, LineNum: Integer): Boolean;
var
  I: Integer;
  HasCode: Boolean;
begin
  Result := False;
  if (FIdx < 0) or (FIdx >= Length(State.Files)) then Exit;
  { check if any code token is on this line }
  HasCode := False;
  for I := 0 to High(State.Files[FIdx].Tokens) do
    if State.Files[FIdx].Tokens[I].Line = LineNum then
    begin
      HasCode := True;
      Break;
    end;
  if HasCode then Exit;
  { check if there's a comment starting on this line }
  for I := 0 to High(State.Files[FIdx].Comments) do
    if State.Files[FIdx].Comments[I].Line = LineNum then
    begin
      Result := True;
      Exit;
    end;
end;
{ Build a merged token array: tokens of FIdx with included files' tokens
  spliced in right after the line containing each include directive. }
procedure BuildMergedTokens(FIdx: Integer; var MT: TMergedTokenArray; Depth: Integer);
var
  I, E, Tgt: Integer;
  procedure AddToken(const T: TRawToken; AFile: Integer);
  var N: Integer;
  begin
    N := Length(MT);
    SetLength(MT, N + 1);
    MT[N].FileIdx := AFile;
    MT[N].Line := T.Line;
    MT[N].Col := T.Col;
    MT[N].Kind := T.Kind;
    MT[N].Text := T.Text;
    MT[N].Lower := T.Lower;
  end;
begin
  if Depth > 16 then Exit;
  if (FIdx < 0) or (FIdx >= Length(State.Files)) then Exit;
  for I := 0 to High(State.Files[FIdx].Tokens) do
  begin
    AddToken(State.Files[FIdx].Tokens[I], FIdx);
    { after this token's line, splice includes that start on that line }
    for E := 0 to High(State.TreeEdges) do
      if (State.TreeEdges[E].ParentFileIdx = FIdx) and
         (State.TreeEdges[E].ParentLine = State.Files[FIdx].Tokens[I].Line) and
         (State.TreeEdges[E].TargetFileIdx >= 0) then
      begin
        Tgt := State.TreeEdges[E].TargetFileIdx;
        BuildMergedTokens(Tgt, MT, Depth + 1);
      end;
  end;
end;



{ Enumerate top-level statement spans within a file line range.
  Uses raw file tokens and a forward scan that respects nested begin/end/case/
  try/repeat blocks, parens/brackets, and statement terminators. Intended for
  block-anchored statement indexing/editing (MVP). }
procedure CollectStatementsInRange(FileIdx, RangeStart, RangeEnd: Integer;
  var Spans: TStmtSpanArray);
var
  Toks: TRawTokenArray;
  I, N, StmtStart, StmtEnd, Cur, Depth, BlkDepth: Integer;
  L: string;
  InBody: Boolean;

  procedure AddSpan(AStart, AEnd: Integer);
  var S: TStmtSpan;
  begin
    if (AStart < 0) or (AEnd < AStart) or (AEnd > High(Toks)) then Exit;
    if Toks[AEnd].Line < RangeStart then Exit;
    if Toks[AStart].Line > RangeEnd then Exit;
    S.FileIdx := FileIdx;
    S.StartLine := Toks[AStart].Line;
    S.StartCol := Toks[AStart].Col;
    S.EndLine := Toks[AEnd].Line;
    S.EndCol := Toks[AEnd].Col + Length(Toks[AEnd].Text);
    N := Length(Spans);
    SetLength(Spans, N + 1);
    Spans[N] := S;
  end;

  function IsBlockOpen(const S: string): Boolean;
  begin
    Result := (S = 'begin') or (S = 'case') or (S = 'try') or (S = 'repeat') or (S = 'asm');
  end;
  function IsBlockClose(const S: string): Boolean;
  begin
    Result := (S = 'end') or (S = 'until');
  end;

begin
  SetLength(Spans, 0);
  if (FileIdx < 0) or (FileIdx >= Length(State.Files)) then Exit;
  Toks := State.Files[FileIdx].Tokens;
  if Length(Toks) = 0 then Exit;
  N := 0;

  { Find first token at or after RangeStart }
  I := 0;
  while (I < Length(Toks)) and (Toks[I].Line < RangeStart) do Inc(I);

  { If range starts at a begin, step inside it for top-level body statements }
  InBody := False;
  if (I < Length(Toks)) and (Toks[I].Line <= RangeEnd) and (LowerCase(Toks[I].Text) = 'begin') then
  begin
    InBody := True;
    Inc(I);
  end;

  while I < Length(Toks) do
  begin
    if Toks[I].Line > RangeEnd then Break;
    L := LowerCase(Toks[I].Text);

    { Skip separators/noise at top level }
    if Toks[I].Kind = tkDirective then begin Inc(I); Continue; end;
    if (Toks[I].Text = ';') then begin Inc(I); Continue; end;
    if IsBlockClose(L) then
    begin
      if InBody then Break; { end of our begin..end range }
      Inc(I);
      Continue;
    end;

    StmtStart := I;
    Depth := 0;
    BlkDepth := 0;
    StmtEnd := I;
    Cur := I;
    while Cur < Length(Toks) do
    begin
      if Toks[Cur].Line > RangeEnd then begin StmtEnd := Cur - 1; Break; end;
      L := LowerCase(Toks[Cur].Text);
      StmtEnd := Cur;
      if (Depth = 0) and (Toks[Cur].Kind = tkDirective) then
      begin StmtEnd := Cur - 1; Break; end;

      if (Toks[Cur].Text = '(') or (Toks[Cur].Text = '[') then Inc(Depth)
      else if (Toks[Cur].Text = ')') or (Toks[Cur].Text = ']') then begin if Depth > 0 then Dec(Depth); end
      else if Depth = 0 then
      begin
        if IsBlockOpen(L) then Inc(BlkDepth)
        else if IsBlockClose(L) then
        begin
          if BlkDepth > 0 then Dec(BlkDepth)
          else begin
            { closing our containing block - do not consume it }
            StmtEnd := Cur - 1;
            Break;
          end;
        end
        else if (Toks[Cur].Text = ';') and (BlkDepth = 0) then
        begin
          StmtEnd := Cur; { include semicolon in span }
          Inc(Cur);
          Break;
        end;
      end;
      Inc(Cur);
    end;

    if StmtEnd >= StmtStart then
      AddSpan(StmtStart, StmtEnd);

    if Cur <= I then Inc(Cur);
    I := Cur;
    if (I < Length(Toks)) and IsBlockClose(LowerCase(Toks[I].Text)) and InBody and (BlkDepth <= 0) then
      Break;
  end;
end;





procedure CollectBodyStatements(FIdx, RangeStart, RangeEnd: Integer; var Spans: TStmtSpanArray); forward;



function ResolveBlockForStmts(const Target: string; out BIdx: Integer; out FIdx, SLine, ELine: Integer): Boolean;
var B: TLogicBlock;


begin
  Result := False; BIdx := -1; FIdx := -1; SLine := 0; ELine := 0;
  BIdx := ResolveBlockTargetIndex(Target);
  if BIdx < 0 then Exit;
  B := State.LogicBlocks[BIdx];
  FIdx := B.FileIdx;
  SLine := B.StartLine;
  ELine := B.EndLine;
  Result := (FIdx >= 0) and (SLine > 0) and (ELine >= SLine);
end;




function SplitDrillPath(const Path: string; out Components: TStringArray): Integer;
var
  I, Start: Integer;
  C: Char;
begin
  SetLength(Components, 0);
  if Trim(Path) = '' then Exit(0);
  Start := 1;
  for I := 1 to Length(Path) + 1 do
  begin
    if (I > Length(Path)) or (Path[I] = '/') then
    begin
      if I > Start then
      begin
        SetLength(Components, Length(Components) + 1);
        Components[High(Components)] := Trim(Copy(Path, Start, I - Start));
      end;
      Start := I + 1;
    end;
  end;
  Result := Length(Components);
end;

function DrillIntoStatement(const S: TStmtSpan; out BodyStart, BodyEnd: Integer; out InnerSpans: TStmtSpanArray): Boolean;
var
  Toks: TRawTokenArray;
  SI, EI, TI: Integer;
  FirstText: string;
begin
  Result := False;
  BodyStart := S.StartLine; BodyEnd := S.EndLine;
  SetLength(InnerSpans, 0);
  if (S.FileIdx < 0) or (S.FileIdx >= Length(State.Files)) then Exit;
  Toks := State.Files[S.FileIdx].Tokens;
  if Length(Toks) = 0 then Exit;
  SI := -1; EI := -1;
  for TI := 0 to High(Toks) do
  begin
    if (SI < 0) and (Toks[TI].Line = S.StartLine) and (Toks[TI].Col = S.StartCol) then SI := TI;
    if (Toks[TI].Line = S.EndLine) and (Toks[TI].Col + Length(Toks[TI].Text) >= S.EndCol - 1) then
      EI := TI;
  end;
  if (SI < 0) or (EI < 0) then Exit;
  FirstText := LowerCase(Toks[SI].Text);
  { If it's a begin..end compound, collect inner statements }
  if FirstText = 'begin' then
  begin
    CollectStatementsInRange(S.FileIdx, S.StartLine, S.EndLine, InnerSpans);
    BodyStart := S.StartLine; BodyEnd := S.EndLine;
    Result := Length(InnerSpans) > 0;
    Exit;
  end;
  { For control-flow statements, find the begin..end body }
  if (FirstText = 'if') or (FirstText = 'for') or (FirstText = 'while') or
     (FirstText = 'repeat') or (FirstText = 'case') or (FirstText = 'with') then
  begin
    BodyStart := -1; BodyEnd := -1;
    for TI := SI to EI do
    begin
      if (BodyStart < 0) and (LowerCase(Toks[TI].Text) = 'begin') then
        BodyStart := Toks[TI].Line;
    end;
    if BodyStart >= 0 then
    begin
      BodyEnd := S.EndLine;
      for TI := EI downto SI do
      begin
        if LowerCase(Toks[TI].Text) = 'end' then
        begin
          BodyEnd := Toks[TI].Line;
          Break;
        end;
      end;
      CollectStatementsInRange(S.FileIdx, BodyStart, BodyEnd, InnerSpans);
      Result := Length(InnerSpans) > 0;
    end;
  end;
end;


function ResolveDrillPath(const Path: string; out S: TStmtSpan; out FIdx, SLine, ELine: Integer): Boolean;
var
  Components: TStringArray;
  N, I, Idx: Integer;
  BIdx: Integer;
  Spans: TStmtSpanArray;
  SubSpans: TStmtSpanArray;
  CurSpan: TStmtSpan;
  BodyStart, BodyEnd: Integer;



begin
  Result := False;
  FIdx := -1; SLine := 0; ELine := 0;
  N := SplitDrillPath(Path, Components);
  if N = 0 then Exit;
  { First component must resolve to a block }


  if not ResolveBlockForStmts(Components[0], BIdx, FIdx, SLine, ELine) then Exit;
  CurSpan.FileIdx := FIdx;
  CurSpan.StartLine := SLine;
  CurSpan.StartCol := 1;
  CurSpan.EndLine := ELine;
  CurSpan.EndCol := 1;
  { For the first block, collect statements }
  CollectBodyStatements(FIdx, SLine, ELine, Spans);
  { Process remaining numeric components }
  for I := 1 to N - 1 do
  begin
    if not TryStrToInt(Components[I], Idx) then Exit;
    if (Idx < 1) or (Idx > Length(Spans)) then Exit;
    CurSpan := Spans[Idx - 1];
    { Try to drill into this statement }
    BodyStart := 0; BodyEnd := 0;
    if DrillIntoStatement(CurSpan, BodyStart, BodyEnd, SubSpans) then
    begin
      { Create a span covering the body for the next level or final result }
      CurSpan.StartLine := BodyStart;
      CurSpan.StartCol := 1;
      CurSpan.EndLine := BodyEnd;
      CurSpan.EndCol := 1;
      Spans := SubSpans;
    end
    else
    begin
      { Leaf statement - cannot drill deeper }
      if I < N - 1 then Exit; { more components but no children }
      Break;
    end;
  end;
  S := CurSpan;


  FIdx := S.FileIdx;
  SLine := S.StartLine;
  ELine := S.EndLine;
  Result := (FIdx >= 0) and (SLine > 0) and (ELine >= SLine);
end;








function IsCompoundSpan(const S: TStmtSpan; out InnerStart, InnerEnd: Integer): Boolean;
var
  Toks: TRawTokenArray;
  TI, SI, EI: Integer;
  FirstText, LastText: string;
begin
  Result := False;
  InnerStart := 0; InnerEnd := 0;
  if (S.FileIdx < 0) or (S.FileIdx >= Length(State.Files)) then Exit;
  Toks := State.Files[S.FileIdx].Tokens;
  if Length(Toks) = 0 then Exit;
  if (S.StartLine < 1) or (S.EndLine < S.StartLine) then Exit;
  SI := -1; EI := -1;
  for TI := 0 to High(Toks) do
  begin
    if (SI < 0) and (Toks[TI].Line = S.StartLine) and (Toks[TI].Col = S.StartCol) then
      SI := TI;
    if (Toks[TI].Line = S.EndLine) and (LowerCase(Toks[TI].Text) = 'end') then
      EI := TI;
  end;
  if (SI < 0) or (EI < 0) or (EI <= SI) then Exit;
  FirstText := LowerCase(Toks[SI].Text);
  LastText := LowerCase(Toks[EI].Text);
  if (FirstText <> 'begin') or (LastText <> 'end') then Exit;
  InnerStart := S.StartLine;
  InnerEnd := S.EndLine;
  Result := True;
end;



procedure CollectBodyStatements(FIdx, RangeStart, RangeEnd: Integer; var Spans: TStmtSpanArray);
var


  I, Pass: Integer;
  Last: TStmtSpan;
  Sub: TStmtSpanArray;
  InnerStart, InnerEnd: Integer;
  Changed: Boolean;
begin
  CollectStatementsInRange(FIdx, RangeStart, RangeEnd, Spans);
  { Unwrap a trailing/sole compound begin..end that represents the block body.
    This makes routine bodies and simple compound blocks editable at statement
    granularity instead of returning the whole begin..end as one statement. }
  for Pass := 1 to 3 do
  begin
    Changed := False;
    if Length(Spans) = 0 then Exit;
    if Length(Spans) = 1 then
    begin
      Last := Spans[0];
      if IsCompoundSpan(Last, InnerStart, InnerEnd) and
         (Last.StartLine <= RangeStart + 1) and (Last.EndLine >= RangeEnd - 1) then
      begin
        CollectStatementsInRange(Last.FileIdx, Last.StartLine, Last.EndLine, Sub);
        if Length(Sub) > 0 then begin Spans := Sub; Changed := True; end;
      end;
    end
    else
    begin
      Last := Spans[High(Spans)];
      if IsCompoundSpan(Last, InnerStart, InnerEnd) and (Last.EndLine >= RangeEnd - 1) then
      begin
        CollectStatementsInRange(Last.FileIdx, Last.StartLine, Last.EndLine, Sub);
        if Length(Sub) > 0 then
        begin
           SetLength(Spans, Length(Spans) - 1);


          for I := 0 to High(Sub) do
          begin
            SetLength(Spans, Length(Spans) + 1);
            Spans[High(Spans)] := Sub[I];
          end;
          Changed := True;
        end;
      end;
    end;
    if not Changed then Break;
  end;
end;


procedure EmitStmtListForTarget(const Target: string);
var
  BIdx, FIdx, SLine, ELine, I: Integer;
  S: TStmtSpan;
  Spans: TStmtSpanArray;
  Preview: string;




begin
  { Drill-down path support: Foo/3 means statement 3 of Foo, Foo/3/2 means statement 2 of statement 3 }
  if Pos('/', Target) > 0 then
  begin
    if not ResolveDrillPath(Target, S, FIdx, SLine, ELine) then
    begin
      WriteLn(ErrOutput, 'Drill-down target not found: ', Target);
      Halt(1);
    end;
    BIdx := -1; { no single block for drill-down }
  end
  else if not ResolveBlockForStmts(Target, BIdx, FIdx, SLine, ELine) then
  begin
    WriteLn(ErrOutput, 'Statement list target not found: ', Target);
    Halt(1);
  end;


  if BIdx >= 0 then
    CollectGlobalBlockSpans(State.LogicBlocks[BIdx], Spans)
  else
    CollectBodyStatements(FIdx, SLine, ELine, Spans);
  if Options.JsonMode then
  begin
    WriteLn('{"block":"', Target, '","block_id":', State.LogicBlocks[BIdx].Id,
      ',"file":"', FileDisplay(FIdx), '","range":{"start":', SLine, ',"end":', ELine, '}',
      ',"count":', Length(Spans), ',"statements":[');
    for I := 0 to High(Spans) do
    begin
      Write('  {"index":', I + 1, ',"file":"', FileDisplay(Spans[I].FileIdx),
        '","start_line":', Spans[I].StartLine, ',"start_col":', Spans[I].StartCol,
        ',"end_line":', Spans[I].EndLine, ',"end_col":', Spans[I].EndCol, ',"text":"');
      Preview := Trim(GetLineRaw(Spans[I].FileIdx, Spans[I].StartLine));
      Preview := StringReplace(Preview, '"', '\"', [rfReplaceAll]);
      Preview := StringReplace(Preview, '\', '\\', [rfReplaceAll]);
      Write(Preview);
      if I < High(Spans) then WriteLn('"},') else WriteLn('"}');
    end;
    WriteLn(']}');
  end
  else
  begin
  if BIdx >= 0 then
    WriteLn('Statements in ', Target, ' (block #', State.LogicBlocks[BIdx].Id, ', ',
      FileDisplay(FIdx), ':', SLine, '..', ELine, '): ', Length(Spans))
  else
    WriteLn('Statements in ', Target, ' (', FileDisplay(FIdx), ':', SLine, '..', ELine, '): ', Length(Spans));


    for I := 0 to High(Spans) do
    begin
      Preview := Trim(GetLineRaw(FIdx, Spans[I].StartLine));
      if Length(Preview) > 120 then Preview := Copy(Preview, 1, 117) + '...';
      WriteLn(Format('  %d. %s:%d:%d..%d:%d  %s',
        [I + 1, FileDisplay(Spans[I].FileIdx), Spans[I].StartLine, Spans[I].StartCol,
         Spans[I].EndLine, Spans[I].EndCol, Preview]));
    end;
  end;
end;


procedure ResolveStmtEdit(const Target, Action, Text: string; Index1: Integer);
var
  BIdx, FIdx, SLine, ELine: Integer;
  Spans: TStmtSpanArray;
  S: TStmtSpan;
  InsLine: Integer;
begin
  if Index1 < 1 then
  begin
    WriteLn(ErrOutput, 'Statement index must be >= 1');
    Halt(1);
  end;
  if Pos('/', Target) > 0 then
  begin
    if not ResolveDrillPath(Target, S, FIdx, SLine, ELine) then
    begin
      WriteLn(ErrOutput, 'Drill-down target not found: ', Target);
      Halt(1);
    end;
  end
  else if not ResolveBlockForStmts(Target, BIdx, FIdx, SLine, ELine) then
  begin
    WriteLn(ErrOutput, 'Statement edit target not found: ', Target);
    Halt(1);
  end;


  if BIdx >= 0 then
    CollectGlobalBlockSpans(State.LogicBlocks[BIdx], Spans)
  else
    CollectBodyStatements(FIdx, SLine, ELine, Spans);
  if (Index1 < 1) or (Index1 > Length(Spans)) then
  begin
    WriteLn(ErrOutput, 'Statement index out of range: ', Index1, ' (count=', Length(Spans), ')');
    Halt(1);
  end;
  S := Spans[Index1 - 1];
  EditFileIdx := S.FileIdx;
  DoDelete := False; DoReplace := False; DoInsert := False;
  ReplaceText := StringReplace(Text, '\n', LineEnding, [rfReplaceAll]);
  SuppressLineWarn := True;
  if Action = 'delete' then
  begin
    DoDelete := True;
    DeleteTarget := IntToStr(S.StartLine) + '-' + IntToStr(S.EndLine);
  end
  else if Action = 'replace' then
  begin
    DoReplace := True;
    ReplaceTarget := IntToStr(S.StartLine) + '-' + IntToStr(S.EndLine);
  end
  else if Action = 'insert-before' then
  begin
    DoInsert := True;
    InsLine := S.StartLine;
    InsertLoc := IntToStr(InsLine);
    SetLength(InsertLines, 0);
    InsertText := ReplaceText;
  end
  else if Action = 'insert-after' then
  begin
    DoInsert := True;
    InsLine := S.EndLine + 1;
    InsertLoc := IntToStr(InsLine);
    SetLength(InsertLines, 0);
    InsertText := ReplaceText;
  end
  else
  begin
    WriteLn(ErrOutput, 'Unknown statement edit action: ', Action);
    Halt(1);
  end;
  { sync globals -> Options (LoadAppOptions ran earlier) }
  Options.DoDelete := DoDelete;
  Options.DoReplace := DoReplace;
  Options.DoInsert := DoInsert;
  Options.DeleteTarget := DeleteTarget;
  Options.ReplaceTarget := ReplaceTarget;
  Options.ReplaceText := ReplaceText;
  Options.InsertLoc := InsertLoc;
  Options.InsertText := InsertText;
end;






{ Expand a line to full statement using merged (include-aware) tokens.
  Returns line in root file plus optional continuation files/lines. }
procedure ExpandStatementRangeEx(FIdx, LineNum: Integer;
  out StartLn, EndLn: Integer; out StartFile, EndFile: Integer);
var
  MT: TMergedTokenArray;
  I, FirstTok, LastTok, Cur, ParenDepth, BlkDepth, StartTok, EndTok: Integer;
  L: string;
begin
  StartLn := LineNum; EndLn := LineNum; StartFile := FIdx; EndFile := FIdx;
  SetLength(MT, 0);
  BuildMergedTokens(FIdx, MT, 0);

  FirstTok := -1; LastTok := -1;
  for I := 0 to High(MT) do
    if (MT[I].FileIdx = FIdx) and (MT[I].Line = LineNum) then
    begin
      if FirstTok < 0 then FirstTok := I;
      LastTok := I;
    end;
  if FirstTok < 0 then Exit;

  L := LowerCase(MT[FirstTok].Text);
  if (L = 'begin') or (L = 'then') or (L = 'else') or (L = 'do') or (L = 'of') then
    Inc(FirstTok);
  if FirstTok > LastTok then Exit;

  { backward }
  ParenDepth := 0; StartTok := FirstTok; Cur := FirstTok;
  while Cur > 0 do
  begin
    Dec(Cur);
    L := LowerCase(MT[Cur].Text);
    if (MT[Cur].Text = ')') or (MT[Cur].Text = ']') then Inc(ParenDepth)
    else if (MT[Cur].Text = '(') or (MT[Cur].Text = '[') then
    begin
      if ParenDepth = 0 then begin StartTok := Cur + 1; Break; end;
      Dec(ParenDepth);
    end;
    if ParenDepth = 0 then
    begin
      if MT[Cur].Text = ';' then begin StartTok := Cur + 1; Break; end;
      if (L = 'if') or (L = 'while') or (L = 'for') or (L = 'case') or
         (L = 'repeat') or (L = 'try') or (L = 'with') then
      begin StartTok := Cur; Break; end;
      if (L = 'then') or (L = 'do') or (L = 'else') or (L = 'of') then Continue;
      if L = 'begin' then begin StartTok := Cur + 1; Break; end;
    end;
  end;
  if Cur <= 0 then StartTok := 0;

  { forward }
  ParenDepth := 0; BlkDepth := 0; EndTok := LastTok; Cur := LastTok;
  while Cur < High(MT) do
  begin
    Inc(Cur);
    L := LowerCase(MT[Cur].Text);
    if (MT[Cur].Text = '(') or (MT[Cur].Text = '[') then Inc(ParenDepth)
    else if (MT[Cur].Text = ')') or (MT[Cur].Text = ']') then
    begin if ParenDepth > 0 then Dec(ParenDepth); end
    else if ParenDepth = 0 then
    begin
      if (L = 'begin') or (L = 'case') or (L = 'try') or (L = 'repeat') then Inc(BlkDepth)
      else if (L = 'end') or (L = 'until') then
      begin if BlkDepth > 0 then Dec(BlkDepth); end
      else if (MT[Cur].Text = ';') and (BlkDepth = 0) then
      begin EndTok := Cur; Break; end;
    end;
  end;
  if Cur > High(MT) then EndTok := High(MT);

  StartLn := MT[StartTok].Line; StartFile := MT[StartTok].FileIdx;
  EndLn := MT[EndTok].Line; EndFile := MT[EndTok].FileIdx;
end;
procedure ExpandStatementRange(FIdx, LineNum: Integer; out StartLn, EndLn: Integer);
var
  Toks: TRawTokenArray;
  I, FirstTok, LastTok, Cur, ParenDepth, BlkDepth, StartTok, EndTok: Integer;
  L: string;
begin
  StartLn := LineNum;
  EndLn := LineNum;
  if (FIdx < 0) or (FIdx >= Length(State.Files)) then Exit;
  Toks := State.Files[FIdx].Tokens;
  FirstTok := -1;
  LastTok := -1;
  for I := 0 to High(Toks) do
    if Toks[I].Line = LineNum then
    begin
      if FirstTok < 0 then FirstTok := I;
      LastTok := I;
    end;
  if FirstTok < 0 then Exit;

  { If the line starts with a block/statement keyword, start after it }
  L := LowerCase(Toks[FirstTok].Text);
  if (L = 'begin') or (L = 'then') or (L = 'else') or (L = 'do') or (L = 'of') then
    Inc(FirstTok);
  if FirstTok > LastTok then
  begin
    StartLn := LineNum;
    EndLn := LineNum;
    Exit;
  end;

  { Walk backward to statement start }
  ParenDepth := 0;
  StartTok := FirstTok;
  Cur := FirstTok;
  while Cur > 0 do
  begin
    Dec(Cur);
    L := LowerCase(Toks[Cur].Text);
    if (Toks[Cur].Text = ')') or (Toks[Cur].Text = ']') then Inc(ParenDepth)
    else if (Toks[Cur].Text = '(') or (Toks[Cur].Text = '[') then
    begin
      if ParenDepth = 0 then begin StartTok := Cur + 1; Break; end;
      Dec(ParenDepth);
    end;
    if ParenDepth = 0 then
    begin
      if Toks[Cur].Text = ';' then begin StartTok := Cur + 1; Break; end;
      if (L = 'if') or (L = 'while') or (L = 'for') or (L = 'case') or
         (L = 'repeat') or (L = 'try') or (L = 'with') then
      begin
        StartTok := Cur;
        Break;
      end;
      if (L = 'then') or (L = 'do') or (L = 'else') or (L = 'of') then
      begin
        { continue back to the matching if/while/for/case }
        Continue;
      end;
      if L = 'begin' then begin StartTok := Cur + 1; Break; end;
    end;
  end;
  if Cur <= 0 then StartTok := 0;

  { Walk forward to statement end }
  ParenDepth := 0;
  BlkDepth := 0;
  EndTok := LastTok;
  Cur := LastTok;
  while Cur < High(Toks) do
  begin
    Inc(Cur);
    L := LowerCase(Toks[Cur].Text);
    if (Toks[Cur].Text = '(') or (Toks[Cur].Text = '[') then Inc(ParenDepth)
    else if (Toks[Cur].Text = ')') or (Toks[Cur].Text = ']') then
    begin
      if ParenDepth > 0 then Dec(ParenDepth);
    end
    else if ParenDepth = 0 then
    begin
      if (L = 'begin') or (L = 'case') or (L = 'try') or (L = 'repeat') then Inc(BlkDepth)
      else if (L = 'end') or (L = 'until') then
      begin
        if BlkDepth > 0 then Dec(BlkDepth);
      end
      else if (Toks[Cur].Text = ';') and (BlkDepth = 0) then
      begin
        EndTok := Cur;
        Break;
      end;
    end;
  end;
  if Cur > High(Toks) then EndTok := High(Toks);

  StartLn := Toks[StartTok].Line;
  EndLn := Toks[EndTok].Line;
end;
{ Build read-full output: emit source lines for a target, expanding to full
  statement/block boundaries and optionally inlining includes. }
{ Emit a line range from a file, following include directives via TreeEdges.
  When AddInclude is True, an included file's full content is emitted inline
  right after the directive line (recursively, with a depth guard). }
{ Build a per-file, per-line index of TreeEdges so source emission does not
  rescan every edge for every line of large files. }
procedure BuildLineEdgeIndex;
var
  F, E, L: Integer;
begin
  SetLength(EdgeLines, Length(State.Files));
  for F := 0 to High(State.Files) do
    SetLength(EdgeLines[F], Length(State.Files[F].Lines) + 1);
  for E := 0 to High(State.TreeEdges) do
  begin
    F := State.TreeEdges[E].ParentFileIdx;
    L := State.TreeEdges[E].ParentLine;
    if (F >= 0) and (F < Length(EdgeLines)) and
       (L >= 0) and (L < Length(EdgeLines[F])) then
    begin
      SetLength(EdgeLines[F][L], Length(EdgeLines[F][L]) + 1);
      EdgeLines[F][L][High(EdgeLines[F][L])] := E;
    end;
  end;
end;

procedure EmitFileRange(FIdx, StartLn, EndLn: Integer; AddInclude: Boolean; Depth: Integer);
var
  I, AE, EdgeIdx, TgtIdx: Integer;
  L: string;
begin
  if Depth > 16 then Exit;
  if (FIdx < 0) or (FIdx >= Length(State.Files)) then Exit;
  for I := StartLn to EndLn do
  begin
    if (I < 1) or (I > Length(State.Files[FIdx].Lines)) then Continue;
    L := State.Files[FIdx].Lines[I - 1];
    WriteLn(Output, L);
    if AddInclude and (FIdx < Length(EdgeLines)) and (I < Length(EdgeLines[FIdx])) then
      for AE := 0 to High(EdgeLines[FIdx][I]) do
      begin
        EdgeIdx := EdgeLines[FIdx][I][AE];
        if State.TreeEdges[EdgeIdx].TargetFileIdx >= 0 then
        begin
          TgtIdx := State.TreeEdges[EdgeIdx].TargetFileIdx;
          WriteLn(Output, '  >>> include: ', State.Files[TgtIdx].DisplayName);
          EmitFileRange(TgtIdx, 1, Length(State.Files[TgtIdx].Lines), AddInclude, Depth + 1);
        end;
      end;
  end;
end;
procedure EmitReadFull(FIdx, LineNum: Integer; Mode: string; AddInclude, AddBlock: Boolean);
var
  StartLn, EndLn, BlkIdx: Integer;
  StartFile, EndFile: Integer;
  IncLine, E: Integer;
begin
  StartLn := LineNum;
  EndLn := LineNum;
  StartFile := FIdx;
  EndFile := FIdx;

  if Mode = 'statement' then
    ExpandStatementRangeEx(FIdx, LineNum, StartLn, EndLn, StartFile, EndFile)
  else if Mode = 'block' then
  begin
    BlkIdx := FindBlockAtLine(FIdx, LineNum);
    if BlkIdx >= 0 then
    begin
      StartLn := State.LogicBlocks[BlkIdx].StartLine;
      EndLn := State.LogicBlocks[BlkIdx].EndLine;
    end;
  end;

  { --add-block: expand to full enclosing block }
  if AddBlock then
  begin
    BlkIdx := FindBlockAtLine(FIdx, StartLn);
    if BlkIdx >= 0 then
      StartLn := State.LogicBlocks[BlkIdx].StartLine;
    BlkIdx := FindBlockAtLine(FIdx, EndLn);
    if BlkIdx >= 0 then
      EndLn := State.LogicBlocks[BlkIdx].EndLine;
  end;

  WriteLn(Output, '--- read-full ', Mode, ' line ', LineNum, ' (', StartLn, '..', EndLn, ') ---');

  if StartFile = EndFile then
    EmitFileRange(StartFile, StartLn, EndLn, AddInclude, 0)
  else
  begin
    IncLine := 0;
    for E := 0 to High(State.TreeEdges) do
      if (State.TreeEdges[E].ParentFileIdx = StartFile) and
         (State.TreeEdges[E].TargetFileIdx = EndFile) and
         (State.TreeEdges[E].ParentLine >= StartLn) then
      begin IncLine := State.TreeEdges[E].ParentLine; Break; end;
    if IncLine = 0 then IncLine := StartLn - 1;
    EmitFileRange(StartFile, StartLn, IncLine - 1, False, 0);
    if IncLine > 0 then EmitFileRange(StartFile, IncLine, IncLine, False, 0);
    EmitFileRange(EndFile, 1, EndLn, AddInclude, 0);
  end;
end;

{ Emit raw source for a line range, with include directives expanded inline.
  The directive line itself is replaced by the included source so the result is
  a single continuous compilable text. }
procedure EmitGetBlockLinesToSL(FIdx, StartLn, EndLn: Integer; ExpandIncludes: Boolean;
  Depth: Integer; SL: TStringList);
var
  I, AE, EdgeIdx, TgtIdx: Integer;
  HasInclude: Boolean;
begin
  if Depth > 16 then Exit;
  if (FIdx < 0) or (FIdx >= Length(State.Files)) then Exit;
  if StartLn < 1 then StartLn := 1;
  if EndLn > Length(State.Files[FIdx].Lines) then EndLn := Length(State.Files[FIdx].Lines);
  if StartLn > EndLn then Exit;
  for I := StartLn to EndLn do
  begin
    HasInclude := False;
    if ExpandIncludes and (FIdx < Length(EdgeLines)) and (I < Length(EdgeLines[FIdx])) then
      for AE := 0 to High(EdgeLines[FIdx][I]) do
      begin
        EdgeIdx := EdgeLines[FIdx][I][AE];
        if (State.TreeEdges[EdgeIdx].EdgeKind <> 'uses') and
           (State.TreeEdges[EdgeIdx].TargetFileIdx >= 0) then
        begin
          HasInclude := True;
          TgtIdx := State.TreeEdges[EdgeIdx].TargetFileIdx;
          EmitGetBlockLinesToSL(TgtIdx, 1, Length(State.Files[TgtIdx].Lines), True, Depth + 1, SL);
          Break;
        end;
      end;
    if not HasInclude then
    begin
      if SL = nil then
        WriteLn(Output, GetLineRaw(FIdx, I))
      else
        SL.Add(GetLineRaw(FIdx, I));
    end;
  end;
end;

procedure EmitGetBlockLines(FIdx, StartLn, EndLn: Integer; ExpandIncludes: Boolean;
  Depth: Integer);
begin
  EmitGetBlockLinesToSL(FIdx, StartLn, EndLn, ExpandIncludes, Depth, nil);
end;

{ Emit a full file by walking its root containers in document order. Root
  containers form a non-overlapping covering, so this reconstructs the source
  without absolute line numbers. }
procedure EmitGetBlockFile(FIdx: Integer);
var
  Roots: TIntArray;
  I, RI, RJ, RT, N, NextLine, LastLine, FEnd: Integer;
begin
  if (FIdx < 0) or (FIdx >= Length(State.Files)) then Exit;
  LastLine := Length(State.Files[FIdx].Lines);
  Roots := nil;
  N := 0;
  for I := 0 to High(State.LogicBlocks) do
    if (State.LogicBlocks[I].FileIdx = FIdx) and
       (State.LogicBlocks[I].ParentIdx < 0) then
    begin
      SetLength(Roots, N + 1);
      Roots[N] := I;
      Inc(N);
    end;
  for RI := 1 to N - 1 do
  begin
    RT := Roots[RI];
    RJ := RI - 1;
    while (RJ >= 0) and
          (State.LogicBlocks[Roots[RJ]].StartLine > State.LogicBlocks[RT].StartLine) do
    begin
      Roots[RJ + 1] := Roots[RJ];
      Dec(RJ);
    end;
    Roots[RJ + 1] := RT;
  end;
  NextLine := 1;
  for RI := 0 to N - 1 do
  begin
    I := Roots[RI];
    if State.LogicBlocks[I].EndFileIdx = FIdx then
      FEnd := State.LogicBlocks[I].EndLine
    else
      FEnd := LastLine;
    if State.LogicBlocks[I].StartLine > NextLine then
      EmitGetBlockLines(FIdx, NextLine, State.LogicBlocks[I].StartLine - 1, True, 0);
    EmitGetBlockLines(FIdx, State.LogicBlocks[I].StartLine, FEnd, True, 0);
    if FEnd + 1 > NextLine then NextLine := FEnd + 1;
  end;
  if NextLine <= LastLine then
    EmitGetBlockLines(FIdx, NextLine, LastLine, True, 0);
end;

{ Emit a unit's source with unit/interface/implementation scaffolding removed.
  Interface and implementation declarations are emitted at the uses point;
  initialization/finalization bodies are collected for relocation into main. }
procedure EmitUnitBody(UIdx: Integer; var InitStmts, FiniStmts: TStringArray;
  var Composed: TIntArray);
var
  I, E, LastNonEmpty: Integer;
  LowLine: string;
  InInit, InFini, InInterface, InsideType, Already, HasUses: Boolean;

  procedure EmitUsesDeps;
  var AE, EdgeIdx: Integer;
  begin
    if (UIdx < 0) or (UIdx >= Length(EdgeLines)) or
       (I < 0) or (I >= Length(EdgeLines[UIdx])) then Exit;
    for AE := 0 to High(EdgeLines[UIdx][I]) do
    begin
      EdgeIdx := EdgeLines[UIdx][I][AE];
      if (State.TreeEdges[EdgeIdx].EdgeKind = 'uses') and
         (State.TreeEdges[EdgeIdx].TargetFileIdx >= 0) then
        EmitUnitBody(State.TreeEdges[EdgeIdx].TargetFileIdx, InitStmts, FiniStmts, Composed);
    end;
  end;

begin
  if (UIdx < 0) or (UIdx >= Length(State.Files)) then Exit;
  Already := False;
  for I := 0 to High(Composed) do
    if Composed[I] = UIdx then Already := True;
  if Already then Exit;
  SetLength(Composed, Length(Composed) + 1);
  Composed[High(Composed)] := UIdx;

  LastNonEmpty := Length(State.Files[UIdx].Lines);
  while (LastNonEmpty >= 1) and
        (Trim(State.Files[UIdx].Lines[LastNonEmpty - 1]) = '') do
    Dec(LastNonEmpty);

  InInit := False;
  InFini := False;
  InInterface := False;
  for I := 1 to LastNonEmpty do
  begin
    LowLine := LowerCase(Trim(GetLineRaw(UIdx, I)));

    InsideType := False;
    for E := 0 to High(State.LogicBlocks) do
      if (State.LogicBlocks[E].Kind = bkType) and
         (State.LogicBlocks[E].FileIdx = UIdx) and
         (State.LogicBlocks[E].StartLine <= I) and
         (State.LogicBlocks[E].EndLine >= I) then
      begin
        InsideType := True;
        Break;
      end;

    HasUses := False;
    if (UIdx >= 0) and (UIdx < Length(EdgeLines)) and
       (I >= 0) and (I < Length(EdgeLines[UIdx])) then
      for E := 0 to High(EdgeLines[UIdx][I]) do
        if State.TreeEdges[EdgeLines[UIdx][I][E]].EdgeKind = 'uses' then
        begin
          HasUses := True;
          Break;
        end;
    if HasUses then
    begin
      EmitUsesDeps;
      Continue;
    end;

    if (Copy(LowLine, 1, 5) = 'unit ') and (Pos(';', LowLine) > 0) then Continue;
    if LowLine = 'interface' then
    begin
      InInterface := True;
      Continue;
    end;
    if LowLine = 'implementation' then
    begin
      InInterface := False;
      Continue;
    end;
    { mode/string switches are program-level; duplicating them breaks FPC }
    if Copy(LowLine, 1, 6) = '{$mode' then Continue;
    if (LowLine = '{$h+}') or (LowLine = '{$h-}') then Continue;
    { interface routine headers are redundant in a flat program }
    if InInterface and (not InsideType) and
       ((Copy(LowLine, 1, 9) = 'procedure') or (Copy(LowLine, 1, 8) = 'function')) then
      Continue;
    if LowLine = 'initialization' then
    begin
      InInit := True;
      InFini := False;
      Continue;
    end;
    if LowLine = 'finalization' then
    begin
      InInit := False;
      InFini := True;
      Continue;
    end;
    if (LowLine = 'end.') and (I = LastNonEmpty) then Continue;

    if InInit then
    begin
      SetLength(InitStmts, Length(InitStmts) + 1);
      InitStmts[High(InitStmts)] := GetLineRaw(UIdx, I);
    end
    else if InFini then
    begin
      SetLength(FiniStmts, Length(FiniStmts) + 1);
      FiniStmts[High(FiniStmts)] := GetLineRaw(UIdx, I);
    end
    else
      EmitGetBlockLines(UIdx, I, I, True, 0);
  end;
end;

{ Report likely source-level name collisions before flattening. True Pascal
  overloads/visibility are not modeled, so these are advisory warnings only. }
procedure WarnMonolithClashes;
var
  I, J, K: Integer;
  S1, S2: string;
begin
  for I := 0 to High(State.Types) do
    if State.Types[I].Name <> '' then
      for J := I + 1 to High(State.Types) do
        if (State.Types[J].FileIdx <> State.Types[I].FileIdx) and
           SameText(State.Types[I].Name, State.Types[J].Name) then
        begin
          WriteLn(ErrOutput, 'Warning: duplicate type "', State.Types[I].Name,
            '" in ', FileDisplay(State.Types[I].FileIdx), ' and ',
            FileDisplay(State.Types[J].FileIdx));
          Break;
        end;

  for I := 0 to High(State.Routines) do
    if State.Routines[I].Name <> '' then
      for J := I + 1 to High(State.Routines) do
        if (State.Routines[J].FileIdx <> State.Routines[I].FileIdx) and
           SameText(State.Routines[I].Name, State.Routines[J].Name) then
        begin
          S1 := '';
          for K := 0 to High(State.Routines[I].Params) do
            S1 := S1 + LowerCase(State.Routines[I].Params[K].Detail) + ';';
          S2 := '';
          for K := 0 to High(State.Routines[J].Params) do
            S2 := S2 + LowerCase(State.Routines[J].Params[K].Detail) + ';';
          if S1 = S2 then
          begin
            WriteLn(ErrOutput, 'Warning: duplicate routine "', State.Routines[I].Name,
              '" in ', FileDisplay(State.Routines[I].FileIdx), ' and ',
              FileDisplay(State.Routines[J].FileIdx));
            Break;
          end;
        end;
end;

{ Monolithic program source: replace each uses clause with the used units'
  flattened bodies, and relocate unit init/final bodies into program main. }
procedure EmitMonolithProgram(RootIdx: Integer);
var
  InitStmts, FiniStmts: TStringArray;
  Composed: TIntArray;
  I, J, E, EdgeIdx, MainStart, MainEnd: Integer;
  LowLine: string;
  HasUses: Boolean;
begin
  WarnMonolithClashes;
  InitStmts := nil;
  FiniStmts := nil;
  Composed := nil;
  MainStart := -1;
  MainEnd := -1;
  for I := 0 to High(State.LogicBlocks) do
    if (State.LogicBlocks[I].FileIdx = RootIdx) and
       ((State.LogicBlocks[I].Kind = bkBegin) or
        (State.LogicBlocks[I].Kind = bkInitBlock)) and
       (State.LogicBlocks[I].ParentIdx < 0) and
       (State.LogicBlocks[I].OwnerRoutineIdx < 0) then
    begin
      MainStart := State.LogicBlocks[I].StartLine;
      MainEnd := State.LogicBlocks[I].EndLine;
      Break;
    end;

  for I := 1 to Length(State.Files[RootIdx].Lines) do
  begin
    HasUses := False;
    if (RootIdx >= 0) and (RootIdx < Length(EdgeLines)) and
       (I >= 0) and (I < Length(EdgeLines[RootIdx])) then
      for E := 0 to High(EdgeLines[RootIdx][I]) do
        if State.TreeEdges[EdgeLines[RootIdx][I][E]].EdgeKind = 'uses' then
        begin
          HasUses := True;
          Break;
        end;
    if HasUses then
    begin
      for E := 0 to High(EdgeLines[RootIdx][I]) do
      begin
        EdgeIdx := EdgeLines[RootIdx][I][E];
        if (State.TreeEdges[EdgeIdx].EdgeKind = 'uses') and
           (State.TreeEdges[EdgeIdx].TargetFileIdx >= 0) then
          EmitUnitBody(State.TreeEdges[EdgeIdx].TargetFileIdx, InitStmts, FiniStmts, Composed);
      end;
      Continue;
    end;

    LowLine := LowerCase(Trim(GetLineRaw(RootIdx, I)));
    if (I = MainStart) and (LowLine = 'begin') then
    begin
      WriteLn(Output, GetLineRaw(RootIdx, I));
      for J := 0 to High(InitStmts) do WriteLn(Output, InitStmts[J]);
      Continue;
    end;
    if (I = MainEnd) and (Copy(LowLine, 1, 4) = 'end.') then
    begin
      { finalization runs in reverse initialization/dependency order }
      for J := High(FiniStmts) downto 0 do WriteLn(Output, FiniStmts[J]);
      WriteLn(Output, GetLineRaw(RootIdx, I));
      Continue;
    end;
    EmitGetBlockLines(RootIdx, I, I, True, 0);
  end;
end;

function ResolveBlockTargetToIndex(const T: string): Integer;
begin
  Result := ResolveBlockTargetIndex(T);
end;

{ Build a global line index over every connected file, in load order. }
function GlobalLineOf(FileIdx, Line: Integer): Integer;
var F: Integer;
begin
  Result := 0;
  if (FileIdx < 0) or (FileIdx >= Length(State.Files)) then Exit;
  for F := 0 to FileIdx - 1 do
    Inc(Result, Length(State.Files[F].Lines));
  Inc(Result, Line);
end;

procedure CollectBranchSpans(const Blk: TLogicBlock; var Spans: TStmtSpanArray);
var
  Toks: TRawTokenArray;
  SI, EI, I, J, K, Depth, N: Integer;
  Low: string;
  IsCase: Boolean;
  S: TStmtSpan;
begin
  IsCase := Pos('case', LowerCase(Blk.LabelText)) > 0;
  Toks := State.Files[Blk.FileIdx].Tokens;
  SI := -1; EI := -1;
  for I := 0 to High(Toks) do
  begin
    if (SI < 0) and (Toks[I].Line >= Blk.StartLine) then SI := I;
    if (SI >= 0) and (Toks[I].Line > Blk.EndLine) then Break;
    if (SI >= 0) and (Toks[I].Line <= Blk.EndLine) then EI := I;
  end;
  if (SI < 0) or (EI < SI) then Exit;
  { Single-statement branch bodies: 'if c then S;', 'for .. do S;',
    'while .. do S;', case labels 'N: S;' and 'else S;'. These are real
    statements even without a begin..end wrapper. }
  for I := SI to EI do
  begin
    Low := LowerCase(Toks[I].Text);
 if not ((Low = 'then') or (Low = 'do') or (Low = 'else') or (IsCase and (Low = ':'))) then Continue;
    J := I + 1;
    if J > EI then Continue;
    if LowerCase(Toks[J].Text) = 'begin' then Continue;
    Depth := 0;
    K := J;
    while K <= EI do
    begin
      Low := LowerCase(Toks[K].Text);
      if (Toks[K].Text = '(') or (Toks[K].Text = '[') then Inc(Depth)
      else if (Toks[K].Text = ')') or (Toks[K].Text = ']') then
      begin if Depth > 0 then Dec(Depth); end
      else if (Depth = 0) and
        ((Toks[K].Text = ';') or (Low = 'else') or (Low = 'end')) then Break;
      Inc(K);
    end;
    if K < J then Continue;
    S.FileIdx := Blk.FileIdx;
    S.StartLine := Toks[J].Line;
    S.StartCol := Toks[J].Col;
    if (K <= EI) and (Toks[K].Text = ';') then
    begin
      S.EndLine := Toks[K].Line;
      S.EndCol := Toks[K].Col + 1;
    end
    else if K > J then
    begin
      S.EndLine := Toks[K-1].Line;
      S.EndCol := Toks[K-1].Col + Length(Toks[K-1].Text);
    end
    else Continue;
    N := Length(Spans);
    SetLength(Spans, N + 1);
    Spans[N] := S;
  end;
end;

procedure CollectGlobalBlockSpans(const Blk: TLogicBlock; var Spans: TStmtSpanArray);
var
  Toks: TRawTokenArray;
  I, OpenIdx, K, M: Integer;
  Sub, Extra: TStmtSpanArray;
  Dup: Boolean;
begin
  CollectBodyStatements(Blk.FileIdx, Blk.StartLine, Blk.EndLine, Spans);
  { A control-flow block whose only statement is the whole block hides its
    inner statements. Collect begin..end bodies and single-statement branches. }
  if (Length(Spans) = 1) and (Blk.FileIdx >= 0) and
     (Blk.FileIdx < Length(State.Files)) and
     (Spans[0].StartLine <= Blk.StartLine + 1) and
     (Spans[0].EndLine >= Blk.EndLine - 1) then
  begin
    Toks := State.Files[Blk.FileIdx].Tokens;
    OpenIdx := -1;
    for I := 0 to High(Toks) do
      if (Toks[I].Line >= Blk.StartLine) and (Toks[I].Line <= Blk.EndLine) and
         (LowerCase(Toks[I].Text) = 'begin') then
      begin OpenIdx := I; Break; end;
    if OpenIdx >= 0 then
    begin
      CollectStatementsInRange(Blk.FileIdx, Toks[OpenIdx].Line, Blk.EndLine, Sub);
      if Length(Sub) > 0 then Spans := Sub;
    end;
  end;
  SetLength(Extra, 0);
  CollectBranchSpans(Blk, Extra);
  for K := 0 to High(Extra) do
  begin
    Dup := False;
    for M := 0 to High(Spans) do
      if (Spans[M].FileIdx = Extra[K].FileIdx) and
         (Spans[M].StartLine = Extra[K].StartLine) and
         (Spans[M].StartCol = Extra[K].StartCol) then
      begin Dup := True; Break; end;
    if not Dup then
    begin
      SetLength(Spans, Length(Spans) + 1);
      Spans[High(Spans)] := Extra[K];
    end;
  end;
end;

function GetGSRootName(FIdx: Integer): string;
var Toks: TRawTokenArray; I: Integer;
begin
  Result := '';
  if (FIdx < 0) or (FIdx >= Length(State.Files)) then Exit;
  Toks := State.Files[FIdx].Tokens;
  for I := 0 to High(Toks) - 1 do
    if (Toks[I].Lower = 'program') or (Toks[I].Lower = 'unit') then
      if Toks[I + 1].Kind = tkIdent then
      begin Result := Toks[I + 1].Text; Exit; end;
end;

function GSSegmentForBlock(BIdx: Integer; out Skip: Boolean): string;
var L: string; P: Integer;
begin
  Skip := False;
  Result := '';
  if (BIdx < 0) or (BIdx >= Length(State.LogicBlocks)) then begin Skip := True; Exit; end;
  L := LowerCase(Trim(State.LogicBlocks[BIdx].LabelText));
  if (L = '') or (Pos('uncovered source span', L) > 0) then begin Skip := True; Exit; end;
  if Pos('preamble', L) > 0 then begin Result := 'header'; Exit; end;
  if Pos('uses clause', L) > 0 then begin Result := 'uses'; Exit; end;
  if Pos('declaration section', L) > 0 then
  begin P := Pos(' ', L); Result := Copy(L, 1, P - 1); Exit; end;
  if (Pos('procedure ', L) = 1) or (Pos('function ', L) = 1) or
     (Pos('constructor ', L) = 1) or (Pos('destructor ', L) = 1) then
  begin
    P := Pos(' ', L);
    Result := Trim(Copy(L, P + 1, MaxInt));
    { Drop the parameter list unless an ordinal is needed for an overload. }
    P := Pos('(', Result);
    if P > 0 then Result := Trim(Copy(Result, 1, P - 1));
    Exit;
  end;
  if (Pos('record ', L) = 1) or (Pos('class ', L) = 1) then
  begin P := Pos(' ', L); Result := Copy(L, P + 1, MaxInt); Exit; end;
  if Pos('main begin', L) = 1 then begin Result := 'begin'; Exit; end;
  P := Pos(' ', L);
  if P > 0 then Result := Copy(L, 1, P - 1) else Result := L;
end;

function GSSegmentWithOrdinal(BIdx: Integer): string;
var Base, S2: string; Skip, Skip2: Boolean; P, I, Cnt, Ord: Integer;
begin
  Result := '';
  if (BIdx < 0) or (BIdx >= Length(State.LogicBlocks)) then Exit;
  Base := GSSegmentForBlock(BIdx, Skip);
  if Skip then Exit;
  P := State.LogicBlocks[BIdx].ParentIdx;
  Cnt := 0; Ord := 0;
  for I := 0 to High(State.LogicBlocks) do
    if State.LogicBlocks[I].ParentIdx = P then
    begin
      S2 := GSSegmentForBlock(I, Skip2);
      if (not Skip2) and SameText(S2, Base) then
      begin Inc(Cnt); if I = BIdx then Ord := Cnt; end;
    end;
  if Cnt > 1 then Result := Base + '[' + IntToStr(Ord) + ']' else Result := Base;
end;

function BuildGSSemanticPath(BIdx, StmtIdx: Integer): string;
var Chain: TStringArray; Cur, I: Integer; Seg: string;
begin
  SetLength(Chain, 0);
  Cur := BIdx;
  while Cur >= 0 do
  begin
    Seg := GSSegmentWithOrdinal(Cur);
    if Seg <> '' then begin SetLength(Chain, Length(Chain) + 1); Chain[High(Chain)] := Seg; end;
    Cur := State.LogicBlocks[Cur].ParentIdx;
  end;
  Result := GSRootName;
  for I := High(Chain) downto 0 do Result := Result + '.' + Chain[I];
  Result := Result + '.' + IntToStr(StmtIdx);
end;

function FindGSSemanticPathIndex(const S: string): Integer;
var I: Integer;
begin
  Result := 0;
  for I := 0 to High(GStmts) do
    if SameText(GStmts[I].SemanticPath, Trim(S)) then begin Result := I + 1; Exit; end;
end;

procedure BuildGlobalStmtMap;
var
  B, S, I, J, K, N, Best, BestDepth, SubIdx, CurBest: Integer;
  SortedSpan: TStmtSpan;
  Spans, SubSpans: TStmtSpanArray;
  Info, Tmp: TGlobalStmtInfo;
  Duplicate: Boolean;
  Blk: TLogicBlock;
begin
  SetLength(GStmts, 0);
  GSRootName := GetGSRootName(0);
  { Phase 1: collect unique statement spans. }
  for B := 0 to High(State.LogicBlocks) do
  begin
    Blk := State.LogicBlocks[B];
    if (Blk.FileIdx < 0) or (Blk.FileIdx >= Length(State.Files)) then Continue;
    CollectGlobalBlockSpans(Blk, Spans);
    for S := 0 to High(Spans) do
    begin
      Duplicate := False;
      for I := 0 to High(GStmts) do
        if (GStmts[I].FileIdx = Spans[S].FileIdx) and
           (GStmts[I].StartLine = Spans[S].StartLine) and
           (GStmts[I].StartCol = Spans[S].StartCol) and
           (GStmts[I].EndLine = Spans[S].EndLine) and
           (GStmts[I].EndCol = Spans[S].EndCol) then
        begin Duplicate := True; Break; end;
      if Duplicate then Continue;
      Info.FileIdx := Spans[S].FileIdx;
      Info.StartLine := Spans[S].StartLine;
      Info.StartCol := Spans[S].StartCol;
      Info.EndLine := Spans[S].EndLine;
      Info.EndCol := Spans[S].EndCol;
      Info.GlobalLine := GlobalLineOf(Info.FileIdx, Info.StartLine);
      Info.Inactive := IsLineCondInactive(Info.FileIdx, Info.StartLine);
      Info.LineOrdinal := 1;
      Info.BlockIdx := -1;
      Info.StmtIdx := 0;
      Info.Path := '';
      Info.SemanticPath := '';
      Info.Context := '';
      Info.Text := Trim(GetLineRaw(Info.FileIdx, Info.StartLine));
      if Length(Info.Text) > 120 then Info.Text := Copy(Info.Text, 1, 117) + '...';
      N := Length(GStmts);
      SetLength(GStmts, N + 1);
      GStmts[N] := Info;
    end;
  end;
  { Phase 2: innermost owning block and its statement index. This makes paths
    mirror nesting and keeps indices in source order within each block. }
  for I := 0 to High(GStmts) do
  begin
    Best := -1;
    BestDepth := -1;
    for B := 0 to High(State.LogicBlocks) do
    begin
      Blk := State.LogicBlocks[B];
      if Blk.FileIdx <> GStmts[I].FileIdx then Continue;
      if (Blk.StartLine > GStmts[I].StartLine) or
         (Blk.EndLine < GStmts[I].EndLine) then Continue;
      if (Blk.Depth > BestDepth) or
         ((Blk.Depth = BestDepth) and (B > Best)) then
      begin Best := B; BestDepth := Blk.Depth; end;
    end;
    if Best < 0 then Continue;
    SubIdx := 0;
    CurBest := Best;
    while (CurBest >= 0) and (SubIdx = 0) do
    begin
      CollectGlobalBlockSpans(State.LogicBlocks[CurBest], SubSpans);
      { Index statements in source order within the owning block. }
      for J := 1 to High(SubSpans) do
      begin
        SortedSpan := SubSpans[J];
        K := J - 1;
        while (K >= 0) and
          ((SubSpans[K].StartLine > SortedSpan.StartLine) or
           ((SubSpans[K].StartLine = SortedSpan.StartLine) and
            (SubSpans[K].StartCol > SortedSpan.StartCol))) do
        begin
          SubSpans[K + 1] := SubSpans[K];
          Dec(K);
        end;
        SubSpans[K + 1] := SortedSpan;
      end;
      for J := 0 to High(SubSpans) do
        if (SubSpans[J].StartLine = GStmts[I].StartLine) and
           (SubSpans[J].StartCol = GStmts[I].StartCol) and
           (SubSpans[J].EndLine = GStmts[I].EndLine) and
           (SubSpans[J].EndCol = GStmts[I].EndCol) then
        begin SubIdx := J + 1; Break; end;
      if SubIdx > 0 then
        Best := CurBest
      else
        CurBest := State.LogicBlocks[CurBest].ParentIdx;
    end;
    GStmts[I].BlockIdx := Best;
    if SubIdx = 0 then SubIdx := 1;
    GStmts[I].StmtIdx := SubIdx;
    GStmts[I].Path := '#' + IntToStr(State.LogicBlocks[Best].Id) + '/' + IntToStr(SubIdx);
    GStmts[I].SemanticPath := BuildGSSemanticPath(Best, SubIdx);
    GStmts[I].Context := State.LogicBlocks[Best].LabelText;
    if (State.LogicBlocks[Best].OwnerRoutineIdx >= 0) and
       (State.LogicBlocks[Best].OwnerRoutineIdx < Length(State.Routines)) then
      GStmts[I].Context := State.Routines[State.LogicBlocks[Best].OwnerRoutineIdx].Name +
        ' -> ' + GStmts[I].Context;
  end;
  { Phase 3: sort by file load order, then source position, then ordinals. }
  for I := 1 to High(GStmts) do
  begin
    Tmp := GStmts[I];
    J := I - 1;
    while (J >= 0) and
      ((GStmts[J].FileIdx > Tmp.FileIdx) or
       ((GStmts[J].FileIdx = Tmp.FileIdx) and
        ((GStmts[J].StartLine > Tmp.StartLine) or
         ((GStmts[J].StartLine = Tmp.StartLine) and
          (GStmts[J].StartCol > Tmp.StartCol))))) do
    begin
      GStmts[J + 1] := GStmts[J];
      Dec(J);
    end;
    GStmts[J + 1] := Tmp;
  end;
  for I := 0 to High(GStmts) do
  begin
    if (I > 0) and (GStmts[I - 1].GlobalLine = GStmts[I].GlobalLine) then
      GStmts[I].LineOrdinal := GStmts[I - 1].LineOrdinal + 1
    else
      GStmts[I].LineOrdinal := 1;
  end;
end;
function GSPathAtLine(FileIdx, Line: Integer): string;
var I, GL, GE: Integer;
begin
  Result := '';
  if Length(GStmts) = 0 then BuildGlobalStmtMap;
  GL := GlobalLineOf(FileIdx, Line);
  { Prefer a statement starting on this line. }
  for I := 0 to High(GStmts) do
    if GStmts[I].GlobalLine = GL then begin Result := GStmts[I].SemanticPath; Exit; end;
  { Otherwise the enclosing statement. }
  for I := 0 to High(GStmts) do
  begin
    GE := GlobalLineOf(GStmts[I].FileIdx, GStmts[I].EndLine);
    if (GL >= GStmts[I].GlobalLine) and (GL <= GE) then
    begin Result := GStmts[I].SemanticPath; Exit; end;
  end;
end;

function GSLocationTag(FileIdx, Line: Integer): string;
var P: string;
begin
  P := GSPathAtLine(FileIdx, Line);
  if P = '' then Result := '' else
    if IsLineCondInactive(FileIdx, Line) then Result := '[GS ' + P + ' (inactive)] '
    else Result := '[GS ' + P + '] ';
end;

procedure EmitGLineToGS;
var
  N, I, GE: Integer;
  Found: Boolean;
begin
  N := Options.GlobalLineNum;
  if N < 1 then Exit;
  Found := False;
  for I := 0 to High(GStmts) do
  begin
    GE := GlobalLineOf(GStmts[I].FileIdx, GStmts[I].EndLine);
    if (N >= GStmts[I].GlobalLine) and (N <= GE) then
    begin
      WriteLn(Output, Format('%-40s GS%-4d %-14s %-28s %s',
        [GStmts[I].SemanticPath, I + 1, 'L ' + IntToStr(GStmts[I].GlobalLine) + '.' + IntToStr(GStmts[I].LineOrdinal),
         GStmts[I].Context, GStmts[I].Text]));
      Found := True;
    end;
  end;
  if not Found then
    WriteLn(ErrOutput, 'No GSLine statement covers global line ', N);
end;


procedure EmitGlobalStmts;
var
  A, BEnd, I, DashPos, BIdx: Integer;
  S, Loc, Sel: string;
begin
  if Options.GlobalLineMode or Options.DecodeGSLineMode then
  begin
    A := Options.GlobalLineNum;
    BEnd := A;
    Sel := IntToStr(A);
  end
  else
  begin
    S := Trim(Options.GlobalLinesSpec);
    Sel := S;
    DashPos := Pos('-', S);
    if DashPos > 0 then
    begin
      A := StrToIntDef(Copy(S, 1, DashPos - 1), 1);
      BEnd := StrToIntDef(Copy(S, DashPos + 1, MaxInt), A);
    end
    else
    begin
      A := StrToIntDef(S, 1);
      BEnd := A;
    end;
  end;
  if A < 1 then A := 1;
  if BEnd > Length(GStmts) then BEnd := Length(GStmts);
  if A > BEnd then Exit;
  if Options.JsonMode and (not Options.DecodeGSLineMode) then
  begin
    WriteLn('{');
    WriteLn('  "schema_version": ', JSON_SCHEMA_VERSION, ',');
    WriteLn('  "tool_version": "', FPCAUDIT_VERSION, '",');
    WriteLn('  "parser_version": ', FPCAUDIT_PARSER_VERSION, ',');
    WriteLn('  "selector": "', JsonEscape(Sel), '",');
    WriteLn('  "count": ', BEnd - A + 1, ',');
    WriteLn('  "statements": [');
    for I := A to BEnd do
    begin
      BIdx := GStmts[I - 1].BlockIdx;
      Write('    {"path":"', JsonEscape(GStmts[I - 1].SemanticPath),
        '","gs":', I, ',"file":"', JsonEscape(FileDisplay(GStmts[I - 1].FileIdx)),
        '","global_line":', GStmts[I - 1].GlobalLine,
        ',"line_ordinal":', GStmts[I - 1].LineOrdinal,
        ',"start_line":', GStmts[I - 1].StartLine,
        ',"start_col":', GStmts[I - 1].StartCol,
        ',"end_line":', GStmts[I - 1].EndLine,
        ',"end_col":', GStmts[I - 1].EndCol,
        ',"block_id":');
      if (BIdx >= 0) and (BIdx < Length(State.LogicBlocks)) then
        Write(State.LogicBlocks[BIdx].Id, ',"block_label":"',
          JsonEscape(State.LogicBlocks[BIdx].LabelText), '"')
      else
        Write('0,"block_label":""');
      Write(',"context":"', JsonEscape(GStmts[I - 1].Context),
        '","text":"', JsonEscape(GStmts[I - 1].Text),
        '","inactive":', JsonBool(GStmts[I - 1].Inactive), '}');
      if I < BEnd then WriteLn(',') else WriteLn;
    end;
    WriteLn('  ]');
    WriteLn('}');
    Exit;
  end;
  if not Options.DecodeGSLineMode then
    WriteLn(Output, 'Path                                     GS#   Line          Container                 Statement');
  for I := A to BEnd do
  begin
    if GStmts[I - 1].EndLine > GStmts[I - 1].StartLine then
      Loc := 'L ' + IntToStr(GStmts[I - 1].GlobalLine) + '-' +
             IntToStr(GlobalLineOf(GStmts[I - 1].FileIdx, GStmts[I - 1].EndLine))
    else
      Loc := 'L ' + IntToStr(GStmts[I - 1].GlobalLine) + '.' +
             IntToStr(GStmts[I - 1].LineOrdinal);
    if Options.DecodeGSLineMode then
      WriteLn(Output, GStmts[I - 1].SemanticPath)
    else
      if GStmts[I - 1].Inactive then
        WriteLn(Output, Format('%-40s GS%-4d %-14s %-28s %s [inactive]',
          [GStmts[I - 1].SemanticPath, I, Loc, GStmts[I - 1].Context, GStmts[I - 1].Text]))
      else
        WriteLn(Output, Format('%-40s GS%-4d %-14s %-28s %s',
          [GStmts[I - 1].SemanticPath, I, Loc, GStmts[I - 1].Context, GStmts[I - 1].Text]));
  end;
end;

function IsGSPrefix(const S: string): Boolean;
var T: string;
begin
  T := Trim(S);
  Result := (Length(T) >= 3) and
    ((T[1] = 'G') or (T[1] = 'g')) and
    ((T[2] = 'S') or (T[2] = 's')) and
    (T[3] >= '0') and (T[3] <= '9');
end;

function LooksLikePascalFilePath(const S: string): Boolean;
var L, Ext: string; P: Integer;
begin
  Result := False;
  L := Trim(S);
  if L = '' then Exit;
  if (Pos(' ', L) > 0) or (Pos(#9, L) > 0) then Exit;
  P := Length(L);
  while (P > 0) and (L[P] <> '.') and (L[P] <> '\') and (L[P] <> '/') do Dec(P);
  if P < 1 then Exit;
  Ext := LowerCase(Copy(L, P, MaxInt));
  Result := (Ext = '.pas') or (Ext = '.inc') or (Ext = '.pp') or
            (Ext = '.lpr') or (Ext = '.dpr') or (Ext = '.txt');
  { A bare filename without a path that does not exist is probably literal text. }
  if Result and (Pos('\', L) = 0) and (Pos('/', L) = 0) and (not FileExists(L)) then
    Result := False;
end;

function TranslateGSLineTarget(var Target: string; var Index1: Integer): Boolean;
var S, P: string; N, Slash, K: Integer;
begin
  Result := False;
  S := Trim(Target);
  if Length(S) < 3 then Exit;
  K := FindGSSemanticPathIndex(S);
  if IsGSPrefix(S) then
  begin
    N := StrToIntDef(Copy(S, 3, MaxInt), 0);
    if (N < 1) or (N > Length(GStmts)) then Exit;
  end
  else if K > 0 then
    N := K
  else
    Exit;
  P := GStmts[N - 1].Path;
  Slash := LastDelimiter('/', P);
  if Slash > 0 then
  begin
    Index1 := StrToIntDef(Copy(P, Slash + 1, MaxInt), 0);
    Target := Copy(P, 1, Slash - 1);
  end
  else
    Target := P;
  Result := True;
end;
procedure BuildGlobalLineMap;
var
  F, L: Integer;
begin
  SetLength(GFile, 0);
  SetLength(GLine, 0);
  for F := 0 to High(State.Files) do
    for L := 1 to Length(State.Files[F].Lines) do
    begin
      SetLength(GFile, Length(GFile) + 1);
      SetLength(GLine, Length(GLine) + 1);
      GFile[High(GFile)] := F;
      GLine[High(GLine)] := L;
    end;
end;

procedure EmitGlobalLines;
var
  A, BEnd, I, F, L, DashPos, ScopeIdx: Integer;
  S: string;
  BM: TBlockMatch;
  SB: TLogicBlock;
begin
  if Options.GlobalLineMode then
  begin
    A := Options.GlobalLineNum;
    BEnd := Options.GlobalLineNum;
  end
  else
  begin
    S := Trim(Options.GlobalLinesSpec);
    DashPos := Pos('-', S);
    if DashPos > 0 then
    begin
      A := StrToIntDef(Copy(S, 1, DashPos - 1), 1);
      BEnd := StrToIntDef(Copy(S, DashPos + 1, MaxInt), A);
    end
    else
    begin
      A := StrToIntDef(S, 1);
      BEnd := A;
    end;
  end;
  if A < 1 then A := 1;
  if BEnd > Length(GFile) then BEnd := Length(GFile);
  if A > BEnd then Exit;

  ScopeIdx := -1;
  if Trim(Options.SearchInTarget) <> '' then
  begin
    BM := FindScopedBlockMatch(Options.SearchInTarget);
    if BM.Found then ScopeIdx := BM.BlockIdx;
  end;

  for I := A to BEnd do
  begin
    F := GFile[I - 1];
    L := GLine[I - 1];
    if ScopeIdx >= 0 then
    begin
      SB := State.LogicBlocks[ScopeIdx];
      if (SB.FileIdx <> F) or (L < SB.StartLine) or (L > SB.EndLine) then
        Continue;
    end;
    if Options.GlobalLinesMode then
      WriteLn(Output, Format('%6d  %s:%d: %s',
        [I, FileDisplay(F), L, GetLineRaw(F, L)]))
    else
      WriteLn(Output, GetLineRaw(F, L));
  end;
end;

procedure EmitGetBlock(RootFileIdx: Integer);
var
  Tgt, Part: string;
  Targets: TStringArray;
  IdxList: TIntArray;
  I, J, K, N, Tmp: Integer;
  B: TLogicBlock;
  SL: TStringList;
  HasMain: Boolean;
begin
  Tgt := Trim(Options.GetBlockTarget);
  if (Tgt = '') or SameText(Tgt, 'all') or SameText(Tgt, 'file') or (Tgt = '*') then
  begin
    if Options.UnitsMode then
      EmitMonolithProgram(RootFileIdx)
    else
      EmitGetBlockFile(RootFileIdx);
    Exit;
  end;

  Targets := nil;
  N := 0;
  K := 1;
  while K <= Length(Tgt) do
  begin
    J := K;
    while (J <= Length(Tgt)) and (Tgt[J] <> ',') do Inc(J);
    Part := Trim(Copy(Tgt, K, J - K));
    if Part <> '' then
    begin
      SetLength(Targets, N + 1);
      Targets[N] := Part;
      Inc(N);
    end;
    K := J + 1;
  end;

  SetLength(IdxList, 0);
  for I := 0 to N - 1 do
  begin
    J := ResolveBlockTargetToIndex(Targets[I]);
    if J < 0 then
    begin
      WriteLn(ErrOutput, 'Block target not found: ', Targets[I]);
      Halt(1);
    end;
    Tmp := -1;
    for K := 0 to High(IdxList) do
      if IdxList[K] = J then Tmp := J;
    if Tmp < 0 then
    begin
      SetLength(IdxList, Length(IdxList) + 1);
      IdxList[High(IdxList)] := J;
    end;
  end;

  { emit selected blocks in document order }
  for I := 1 to High(IdxList) do
  begin
    Tmp := IdxList[I];
    J := I - 1;
    while (J >= 0) and
          ((State.LogicBlocks[IdxList[J]].FileIdx > State.LogicBlocks[Tmp].FileIdx) or
           ((State.LogicBlocks[IdxList[J]].FileIdx = State.LogicBlocks[Tmp].FileIdx) and
            (State.LogicBlocks[IdxList[J]].StartLine > State.LogicBlocks[Tmp].StartLine))) do
    begin
      IdxList[J + 1] := IdxList[J];
      Dec(J);
    end;
    IdxList[J + 1] := Tmp;
  end;

  SL := TStringList.Create;
  HasMain := False;
  try
    for I := 0 to High(IdxList) do
    begin
      B := State.LogicBlocks[IdxList[I]];
      if ((B.Kind = bkBegin) or (B.Kind = bkInitBlock)) and
         (B.ParentIdx < 0) and (B.OwnerRoutineIdx < 0) then
        HasMain := True;
      if Options.GetBlockWithOrigin then
        SL.Add('{ ' + LogicBlockTypeTag(B.Kind) + ' #' + IntToStr(B.Id) + ' ' +
          FileDisplay(B.FileIdx) + ':' + IntToStr(B.StartLine) + '..' +
          IntToStr(B.EndLine) + ' }');
      if Options.GetBlockStandalone and (B.Kind = bkType) then
        SL.Add('type');
      EmitGetBlockLinesToSL(B.FileIdx, B.StartLine, B.EndLine, True, 0, SL);
      if B.EndFileIdx <> B.FileIdx then
        EmitGetBlockLinesToSL(B.EndFileIdx, 1, B.EndLine, True, 0, SL);
    end;

    if Options.GetBlockStandalone and (not HasMain) then
    begin
      WriteLn(Output, 'program BlockTest;');
      WriteLn(Output, '{$mode objfpc}{$H+}');
      WriteLn(Output, '');
    end;
    for I := 0 to SL.Count - 1 do WriteLn(Output, SL[I]);
    if Options.GetBlockStandalone and (not HasMain) then
    begin
      WriteLn(Output, '');
      WriteLn(Output, 'begin');
      WriteLn(Output, 'end.');
    end;
  finally
    SL.Free;
  end;
end;

function ResolveTargetToLines(const Target: string; AfterMode: Boolean;
  out StartLn, EndLn: Integer): Boolean;
var
  BIdx, Ln: Integer;
  BM: TBlockMatch;
begin
  Result := False;
  StartLn := 0;
  EndLn := 0;
  if Target = '' then Exit;

  if (Pos('-', Target) > 0) and
     TryStrToInt(Copy(Target, 1, Pos('-', Target) - 1), Ln) then
  begin
    StartLn := StrToIntDef(Copy(Target, 1, Pos('-', Target) - 1), 1);
    EndLn := StrToIntDef(Copy(Target, Pos('-', Target) + 1, MaxInt), StartLn);
    Result := True;
  end
  else if TryStrToInt(Target, Ln) then
  begin
    StartLn := Ln;
    EndLn := Ln;
    Result := True;
  end
  else
  begin
    { A token/fragment target denotes the exact matched line; block/#id/label
      targets still denote the whole block. Without this, a bare fragment edit
      would replace/delete the entire containing block. }
    BM := FindScopedBlockMatch(Target);
    if BM.Found and BM.FromToken and (BM.MatchLine >= 1) then
    begin
      StartLn := BM.MatchLine;
      EndLn := BM.MatchLine;
      Result := True;
    end
    else
    begin
      BIdx := ResolveBlockTargetIndex(Target);
      if BIdx >= 0 then
      begin
        StartLn := State.LogicBlocks[BIdx].StartLine;
        EndLn := State.LogicBlocks[BIdx].EndLine;
        Result := True;
      end;
    end;
  end;

  if Result and AfterMode then
  begin
    StartLn := EndLn + 1;
    EndLn := StartLn;
  end;
end;

{ Write an array of lines to a text file }
procedure WriteLinesToFile(const Path: string; const L: TStringArray);
var
  F: TFileStream;
  I: Integer;
  Tmp: string;
begin
  F := TFileStream.Create(Path, fmCreate);
  try
    for I := 0 to High(L) do
    begin
      Tmp := L[I] + LineEnding;
      if Length(Tmp) > 0 then
        F.WriteBuffer(Tmp[1], Length(Tmp));
    end;
  finally
    F.Free;
  end;
end;

{ --- indentation beautifier helpers (v2.5.3) --- }
function IndentClosingLine(const S: string): Boolean;
var T: string;
begin
  T := S; while (Length(T) > 0) and ((T[1] = ' ') or (T[1] = #9)) do Delete(T, 1, 1); T := LowerCase(T);

  Result := (Copy(T, 1, 3) = 'end') or (Copy(T, 1, 5) = 'until') or
            (Copy(T, 1, 4) = 'else') or (Copy(T, 1, 7) = 'finally') or
            (Copy(T, 1, 6) = 'except');
end;

function IndentLevelFor(LineNo: Integer; const S: string): Integer;
var B: Integer; Closing, BareBegin: Boolean; T: string;
begin
  Result := 0;
  Closing := IndentClosingLine(S);
  T := LowerCase(Trim(S));
  BareBegin := (T = 'begin') or (Copy(T, 1, 6) = 'begin ') and
    ((Trim(Copy(T, 7, MaxInt)) = '') or (Copy(Trim(Copy(T, 7, MaxInt)), 1, 2) = '//') or
     (Copy(Trim(Copy(T, 7, MaxInt)), 1, 1) = '{') or (Copy(Trim(Copy(T, 7, MaxInt)), 1, 2) = '(*'));
  for B := 0 to High(State.LogicBlocks) do
  begin
    if State.LogicBlocks[B].FileIdx <> BeautifyRootIdx then
    begin
      { different file }
    end
    else if (State.LogicBlocks[B].Kind = bkGap) or
            (State.LogicBlocks[B].Kind = bkUnitSection) or
            (State.LogicBlocks[B].Kind = bkDeclSection) or
            (State.LogicBlocks[B].Kind = bkForwardDecl) then
    begin
      { container/declaration block - do not indent content by block depth }
    end
    else if (LineNo > State.LogicBlocks[B].StartLine) and
            (LineNo <= State.LogicBlocks[B].EndLine) then
    begin
      if (LineNo = State.LogicBlocks[B].EndLine) and Closing then
      begin
        { closing keyword aligns with block start }
      end
      else
        Inc(Result);
    end;
  end;
  if BareBegin and (Result > 0) then
    Dec(Result);
end;


procedure ApplyIndentFix;
var
  Lines, NewLines: TStringArray;
  I, P, Level: Integer;
  InComment, StartInComment: Boolean;
  S: string;
  F: TFileStream;
  Tmp: string;
begin
  Lines := State.Files[BeautifyRootIdx].Lines;
  SetLength(NewLines, Length(Lines));
  InComment := False;
  for I := 0 to High(Lines) do
  begin
    S := Lines[I];
    StartInComment := InComment;
    if StartInComment or (Trim(S) = '') then
      NewLines[I] := S
    else
    begin
      Level := IndentLevelFor(I + 1, S);
      if Level < 0 then Level := 0;
      Tmp := '';
      for P := 1 to Level * Options.IndentSize do Tmp := Tmp + ' ';
      while (Length(S) > 0) and ((S[1] = ' ') or (S[1] = #9)) do Delete(S, 1, 1);
      NewLines[I] := Tmp + S;
      S := Lines[I];
    end;
    P := 1;
    while P <= Length(S) do
    begin
      if InComment then
      begin
        if S[P] = '}' then
          InComment := False
        else if (S[P] = '*') and (P < Length(S)) and (S[P + 1] = ')') then
        begin
          InComment := False;
          P := P + 1;
        end;
      end
      else if S[P] = '''' then
      begin
        P := P + 1;
        while P <= Length(S) do
        begin
          if S[P] = '''' then
          begin
            if (P < Length(S)) and (S[P + 1] = '''' ) then
              P := P + 1
            else
              Break;
          end;
          P := P + 1;
        end;
      end
      else if S[P] = '{' then
        InComment := True
      else if (S[P] = '(') and (P < Length(S)) and (S[P + 1] = '*') then
      begin
        InComment := True;
        P := P + 1;
      end
      else if (S[P] = '/') and (P < Length(S)) and (S[P + 1] = '/') then
        Break;
      P := P + 1;
    end;
  end;

  if Options.DiffMode or Options.DryRunMode then
  begin
    EmitUnifiedDiff(Lines, NewLines, Options.TargetFile);
    Halt(0);
  end;
  F := TFileStream.Create(Options.TargetFile, fmCreate);
  try
    for I := 0 to High(NewLines) do
    begin
      Tmp := NewLines[I] + LineEnding;
      if Length(Tmp) > 0 then
        F.WriteBuffer(Tmp[1], Length(Tmp));
    end;
  finally
    F.Free;
  end;
  WriteLn(Output, 'Indentation fixed: ', Options.TargetFile);
  Halt(0);
end;


{ Insert multiple lines into a line array at a 1-based line number }
procedure InsertTextLines(var L: TStringArray; const AddLines: TStringArray; AtLine: Integer);
var
  I, J: Integer;
begin
  if Length(AddLines) = 0 then Exit;
  if AtLine < 1 then AtLine := 1;
  if AtLine > Length(L) + 1 then AtLine := Length(L) + 1;
  for J := High(AddLines) downto 0 do
  begin
    SetLength(L, Length(L) + 1);
    for I := Length(L) - 1 downto AtLine do
      L[I] := L[I - 1];
    L[AtLine - 1] := AddLines[J];
  end;
end;
var
I, RootIdx, ExitCode: Integer;
Param, Spec, BadTok, OptVal, RootNorm: string;
RootCtx: TParseContext;
BM: TBlockMatch;
TopCond: TCondIfItem;
EditStartLine: Integer;
EditEndLine: Integer;
J: Integer;
Lines: TStringArray;
NewLines: TStringArray;
OutPath: string;
FS: TFileStream;
S: string;
InsertedText: string;
SigEnd: Integer;
Sig: string;
FwdDecl: string;
Fwds: TForwardInfoArray;
Impls: TImplInfoArray;
UsedCnt: Integer;
UnusedCnt: Integer;
AmbigCnt: Integer;
NeedCnt: Integer;
TmpPath: string;
TmpNorm: string;
TmpIdx: Integer;
TmpCtx: TParseContext;
VCode: Integer;
MismatchCnt: Integer;
SkipLine: Boolean;
L: string;
FName: string;
FwdSig: string;
procedure AddIncSearchPath(const RawPath: string);
var
  P, Norm: string;
begin
  P := StripIncQuotes(RawPath);
  if P = '' then Exit;
  P := StringReplace(P, '/', DirectorySeparator, [rfReplaceAll]);
  P := StringReplace(P, '\', DirectorySeparator, [rfReplaceAll]);
  Norm := ExpandFileName(P);
  if Norm = '' then Exit;
  SetLength(IncPaths, Length(IncPaths) + 1);
  IncPaths[High(IncPaths)] := Norm;
end;


procedure AddIncSearchPaths(const RawPaths: string);
var
  S: string;
  StartP, I: Integer;
begin
  S := Trim(RawPaths);
  if S = '' then Exit;
  StartP := 1;
  for I := 1 to Length(S) + 1 do
  begin
    if (I > Length(S)) or (S[I] = ';') then
    begin
      if I > StartP then
        AddIncSearchPath(Copy(S, StartP, I - StartP));
      StartP := I + 1;
    end;
  end;
end;

procedure AddIncSearchPathsRelative(const RawPaths, BaseDir: string);
var
  S, Part, Full: string;
  StartP, I: Integer;
begin
  S := Trim(RawPaths);
  if S = '' then Exit;
  StartP := 1;
  for I := 1 to Length(S) + 1 do
  begin
    if (I > Length(S)) or (S[I] = ';') then
    begin
      if I > StartP then
      begin
        Part := StripIncQuotes(Trim(Copy(S, StartP, I - StartP)));
        if Part <> '' then
        begin
          Part := ExpandLazarusPathMacros(Part, BaseDir);
          Part := StringReplace(Part, '/', DirectorySeparator, [rfReplaceAll]);
          Part := StringReplace(Part, '\', DirectorySeparator, [rfReplaceAll]);
          if (BaseDir <> '') and (Length(Part) > 0) and (not (Part[1] in ['\', '/'])) and
             ((Length(Part) < 2) or (Part[2] <> ':')) then
            Full := IncludeTrailingPathDelimiter(BaseDir) + Part
          else
            Full := Part;
          AddIncSearchPath(Full);
        end;
      end;
      StartP := I + 1;
    end;
  end;
end;


procedure AddUniqueString(var Arr: TStringArray; const S: string);
var
  I: Integer;
  N: string;
begin
  N := NormalizePath(S);
  for I := 0 to High(Arr) do
    if SameFilePath(Arr[I], N) then Exit;
  SetLength(Arr, Length(Arr) + 1);
  Arr[High(Arr)] := N;
end;


procedure AutoLoadLazarusProjectPaths;
var
  DirPath, CwdPath, Base, PDir, Lpi, Lpk: string;
  Found: TStringArray;
  I, Depth: Integer;
begin
  if TargetFile = '' then Exit;
  SetLength(Found, 0);

  for I := 0 to High(LazarusProjectFiles) do
    if FileExists(LazarusProjectFiles[I]) then
      AddUniqueString(Found, LazarusProjectFiles[I]);

  DirPath := ExtractFilePath(ExpandFileName(TargetFile));
  Base := ChangeFileExt(ExtractFileName(TargetFile), '');
  Lpi := DirPath + Base + '.lpi';
  Lpk := DirPath + Base + '.lpk';
  if FileExists(Lpi) then AddUniqueString(Found, Lpi)
  else if FileExists(Lpk) then AddUniqueString(Found, Lpk);

  CollectLazarusProjectsInDir(DirPath, Found);
  CwdPath := IncludeTrailingPathDelimiter(ExpandFileName(GetCurrentDir));
  CollectLazarusProjectsInDir(CwdPath, Found);

  PDir := DirPath;
  for Depth := 1 to 5 do
  begin
    CollectLazarusProjectsInDir(PDir, Found);
    PDir := ExtractFilePath(ExcludeTrailingPathDelimiter(PDir));
    if (PDir = '') or (PDir = ExtractFilePath(ExcludeTrailingPathDelimiter(PDir))) then Break;
  end;
  PDir := CwdPath;
  for Depth := 1 to 5 do
  begin
    CollectLazarusProjectsInDir(PDir, Found);
    PDir := ExtractFilePath(ExcludeTrailingPathDelimiter(PDir));
    if (PDir = '') or (PDir = ExtractFilePath(ExcludeTrailingPathDelimiter(PDir))) then Break;
  end;

  for I := 0 to High(Found) do
    LoadLazarusProjectIncludePaths(Found[I]);
end;


function BytePosSuffix(FileIdx, StartLine, EndLine: Integer; ForwardOnly: Boolean): string;
begin
  Result := '';
  if not Options.ShowByteOffsets then Exit;
  if ForwardOnly then
    Result := ' (byte ' + IntToStr(GetFileByteOffset(FileIdx, StartLine, 1)) + ')'
  else
    Result := ' (bytes ' + IntToStr(GetFileByteOffset(FileIdx, StartLine, 1)) + '-' +
      IntToStr(GetLineEndByteOffset(FileIdx, EndLine)) + ')';
end;


function CmdLineHasWarnUnused: Boolean;

var

  I: Integer;

  P: string;

begin

  Result := False;

  for I := 1 to ParamCount do

  begin

    P := LowerCase(ParamStr(I));

    if (P = '--warn-unused') or (P = '--heuristics') then

      Exit(True);

  end;

end;




procedure CollectLazarusProjectsInDir(const Dir: string; var OutList: TStringArray);
var
  SR: TSearchRec;
  D: string;
begin
  D := IncludeTrailingPathDelimiter(ExpandFileName(Dir));
  if FindFirst(D + '*.lpi', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) = 0 then
        AddUniqueString(OutList, D + SR.Name);
    until FindNext(SR) <> 0;
    SysUtils.FindClose(SR);
  end;
  if FindFirst(D + '*.lpk', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) = 0 then
        AddUniqueString(OutList, D + SR.Name);
    until FindNext(SR) <> 0;
    SysUtils.FindClose(SR);
  end;
end;


function ExpandLazarusPathMacros(const S, ProjDir: string): string;
var
  R: string;
begin
  R := S;
  R := StringReplace(R, '$(ProjPath)', ProjDir, [rfReplaceAll, rfIgnoreCase]);
  R := StringReplace(R, '$(ProjDir)', ProjDir, [rfReplaceAll, rfIgnoreCase]);
  R := StringReplace(R, '$ProjPath()', ProjDir, [rfReplaceAll, rfIgnoreCase]);
  R := StringReplace(R, '$(PkgDir)', ProjDir, [rfReplaceAll, rfIgnoreCase]);
  R := StringReplace(R, '$PkgDir()', ProjDir, [rfReplaceAll, rfIgnoreCase]);
  Result := R;
end;


function FormatFlowExprStringCommon(const S: string; AsItem: Boolean): string;
var Callee, ArgsS, Tail: string;
begin
  if TryExtractSimpleCall(S, Callee, ArgsS, Tail) then
    Result := FormatFlowCallString(Callee, ArgsS, AsItem)
  else
    Result := QuoteFlowDataLiteral(S);
end;


function FormatFlowExprString(const S: string): string;
begin
  Result := FormatFlowExprStringCommon(S, False);
end;


function FormatFlowExprStringAsItem(const S: string): string;
begin
  Result := FormatFlowExprStringCommon(S, True);
end;



function FormatRoutineFlow(const Kind, Name, RetType: string; const Params: TUsageItemArray; Terminate: Boolean): string;
var
  I: Integer;
  Parts: string;
  K: string;
begin
  Parts := '';
  for I := 0 to High(Params) do
  begin
    if Parts <> '' then Parts := Parts + ', ';
    if Trim(Params[I].Detail) <> '' then
      Parts := Parts + Params[I].Name + ':' + Trim(Params[I].Detail)
    else
      Parts := Parts + Params[I].Name;
  end;
  K := LowerCase(Trim(Kind));
  Result := K + ' ' + Trim(Name);
  if (K = 'function') and (Trim(RetType) <> '') then
    Result := Result + ':' + Trim(RetType);
  if Parts <> '' then
    Result := Result + ' has ' + Parts;
  if Terminate then
  begin
    if Parts <> '' then
      Result := Result + ';~'
    else
      Result := Result + ';~';
  end;
end;


function FormatUsageFlow(const Item: TUsageItem): string;
var N, D, Callee, Args, Target, Rhs, FlowArgs, FlowRhs: string;
  P: Integer;
  Parts: TStringArray;
  I: Integer;
begin
  N := Trim(Item.Name);
  D := Trim(Item.Detail);
  if Copy(LowerCase(N), 1, 5) = 'call ' then
  begin
    Callee := Trim(Copy(N, 6, MaxInt));
    P := Pos(': ', Callee);
    if P > 0 then
    begin
      Args := Trim(Copy(Callee, P + 2, MaxInt));
      Callee := Trim(Copy(Callee, 1, P - 1));
    end
    else
      Args := '';
    Result := FlowCallHead(Callee);
    if Args <> '' then
    begin
      Parts := SplitTopLevelCSV(Args);
      FlowArgs := '';
      for I := 0 to High(Parts) do
      begin
        if I > 0 then FlowArgs := FlowArgs + ', ';
        FlowArgs := FlowArgs + FormatFlowExprStringAsItem(Parts[I]);
      end;
      Result := Result + ' has ' + FlowArgs + ';~'
    end
    else
      Result := Result + ';~';
    Exit;
  end;
  P := Pos(' := ', N);
  if P > 0 then
  begin
    Target := Trim(Copy(N, 1, P - 1));
    Rhs := Trim(Copy(N, P + 4, MaxInt));
    FlowRhs := FormatFlowExprString(Rhs);
    Result := Target + ' is ' + FlowRhs + ';~';
    Exit;
  end;
  if D <> '' then
  begin
    if (LowerCase(D) = 'read') or (LowerCase(D) = 'write') then
      Result := N + ' has ' + D + ';~'
    else
      Result := N + ': ' + D + ';~';
  end
  else
    Result := N + ';~';
end;


function GetFileByteOffset(FileIdx, LineNum, ColNum: Integer): Int64;
var
  LineIdx: Integer;
  C: Integer;
begin
  Result := -1;
  if (FileIdx < 0) or (FileIdx >= Length(State.Files)) then Exit;
  if (LineNum < 1) or (LineNum > Length(State.Files[FileIdx].Lines)) then Exit;
  if (LineNum - 1 >= Length(State.Files[FileIdx].LineOffsets)) then Exit;
  LineIdx := LineNum - 1;
  C := ColNum;
  if C < 1 then C := 1;
  // 0-based raw byte offset in file content
  Result := Int64(State.Files[FileIdx].LineOffsets[LineIdx] - 1) + Int64(C - 1);
end;


function GetLineEndByteOffset(FileIdx, LineNum: Integer): Int64;
var
  LineIdx: Integer;
begin
  Result := -1;
  if (FileIdx < 0) or (FileIdx >= Length(State.Files)) then Exit;
  if (LineNum < 1) or (LineNum > Length(State.Files[FileIdx].Lines)) then Exit;
  LineIdx := LineNum - 1;
  if (LineIdx + 1 < Length(State.Files[FileIdx].LineOffsets)) then
    Result := Int64(State.Files[FileIdx].LineOffsets[LineIdx + 1] - 1) - 1
  else
    Result := Int64(State.Files[FileIdx].FileSize) - 1;
  if Result < -1 then Result := -1;
end;


function IsSimpleScalarTypeName(const T: string): Boolean;
var L: string;
begin
  L := LowerCase(Trim(T));
  Result := (L='byte') or (L='shortint') or (L='word') or (L='smallint') or (L='integer') or
    (L='longint') or (L='cardinal') or (L='longword') or (L='int64') or (L='qword') or
    (L='char') or (L='ansichar') or (L='widechar') or (L='boolean') or (L='real') or
    (L='single') or (L='double') or (L='extended') or (L='currency');
end;


procedure LoadLazarusProjectIncludePaths(const ProjectFile: string);
var
  SL: TStringList;
  Text, BaseDir: string;
  VStart, VEnd: Integer;
  function ExtractTagValues(const Src, Tag: string): string;
  var
    Q, R: Integer;
    Chunk: string;
  begin
    Result := '';
    Q := 1;
    while True do
    begin
      Q := PosEx('<' + Tag, Src, Q);
      if Q = 0 then Break;
      R := PosEx('>', Src, Q);
      if R = 0 then Break;
      Chunk := Copy(Src, Q, R - Q + 1);
      VStart := Pos('Value="', Chunk);
      if VStart > 0 then
      begin
        VStart := VStart + 7;
        VEnd := VStart;
        while (VEnd <= Length(Chunk)) and (Chunk[VEnd] <> '"') do Inc(VEnd);
        if VEnd > VStart then
        begin
          if Result <> '' then Result := Result + ';';
          Result := Result + Copy(Chunk, VStart, VEnd - VStart);
        end;
      end;
      Q := R + 1;
    end;
  end;
begin
  if (ProjectFile = '') or (not FileExists(ProjectFile)) then Exit;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(ProjectFile);
    Text := SL.Text;
  finally
    SL.Free;
  end;
  BaseDir := ExtractFilePath(ExpandFileName(ProjectFile));
  AddIncSearchPathsRelative(ExtractTagValues(Text, 'IncludeFiles'), BaseDir);
  AddIncSearchPathsRelative(ExtractTagValues(Text, 'SrcPath'), BaseDir);
  AddIncSearchPathsRelative(ExtractTagValues(Text, 'OtherUnitFiles'), BaseDir);
end;


function QuoteFlowDataLiteral(const S: string): string;
var T: string;
begin
  T := Trim(S);
  if IsQuotedLiteral(T) then
  begin
    Result := T;
    Exit;
  end;
  if IsNumericLiteralText(T) then
  begin
    if (Pos('.', T) > 0) or (Pos('e', LowerCase(T)) > 0) then
      Result := '''' + T + ''':real'
    else
      Result := '''' + T + ''':integer';
  end
  else
    Result := T;
end;


function QuoteFlowDataLiteralTyped(const S, TypeHint: string): string;
var T, TH: string;
begin
  Result := QuoteFlowDataLiteral(S);
  T := Trim(S);
  TH := Trim(TypeHint);
  if (TH = '') or (not IsNumericLiteralText(T)) then Exit;
  { keep real literals as real unless hint explicitly real }
  if (Pos('.', T) > 0) or (Pos('e', LowerCase(T)) > 0) then
  begin
    Result := '''' + T + ''':real';
    Exit;
  end;
  Result := '''' + T + ''':' + TH;
end;


function RoutineUsesDeclaredName(const R: TRoutineInfo; const DeclName: string): Boolean;
var
  I, P: Integer;
  CallName: string;
begin
  Result := False;
  for I := 0 to High(R.Vars) do
    if UsageRefersToName(R.Vars[I].Name, DeclName) then Exit(True);
  for I := 0 to High(R.Assigns) do
    if UsageRefersToName(R.Assigns[I].Name, DeclName) then Exit(True);
  for I := 0 to High(R.Calls) do
  begin
    CallName := R.Calls[I].Name;
    if Copy(CallName, 1, 5) = 'call ' then
      CallName := Copy(CallName, 6, MaxInt);
    P := Pos(':', CallName);
    if P > 0 then CallName := Copy(CallName, 1, P - 1);
    P := Pos(' ', CallName);
    if P > 0 then CallName := Copy(CallName, 1, P - 1);
    if UsageRefersToName(CallName, DeclName) then Exit(True);
  end;
end;





procedure RunHeuristicChecks;
var
  I, J: Integer;
  R: TRoutineInfo;
  Decl: TUsageItem;
  DFile, DLine, DCol: Integer;
begin
  for I := 0 to High(State.Routines) do
  begin
    R := State.Routines[I];
    { Parameters are often intentionally unused (callbacks/interfaces/overrides); skip to reduce noise. }
    for J := 0 to High(R.Locals) do
    begin
      Decl := R.Locals[J];
      if not RoutineUsesDeclaredName(R, Decl.Name) then
      begin
        if Length(Decl.Sites) > 0 then
        begin
          DFile := Decl.Sites[0].FileIdx; DLine := Decl.Sites[0].Line; DCol := 1;
        end
        else
        begin
          DFile := R.FileIdx; DLine := R.StartLine; DCol := 1;
        end;
        AddDiagnostic(DFile, DLine, DCol, EXIT_BIT_WARNING,
          'Possibly unused local variable "' + Decl.Name + '" in ' + R.Kind + ' ' + R.Name);
      end;
    end;
  end;
end;

{ --strict: surface places where the analysis is deliberately heuristic.
  These are warnings (bit 16), so a CI gate requiring ExitMask 0 will fail. }

function IsDeclaredSymbol(const Name: string): Boolean; forward;
procedure RunStrictChecks;
var
  I, J, P, BasePos, Reported: Integer;
  R: TRoutineInfo;
  DFile, DLine, RR: Integer;
  InRoutine: Boolean;
  CallName, Base: string;
  K: Integer;
  SeenCalls: TStringArray;
  Key: string;
  S: Integer;
begin
  for I := 0 to High(State.TreeEdges) do
    if (State.TreeEdges[I].TargetFileIdx >= 0) and
       SameText(State.TreeEdges[I].Resolution, 'cwd') then
      AddDiagnostic(State.TreeEdges[I].ParentFileIdx, State.TreeEdges[I].ParentLine, 1,
        EXIT_BIT_WARNING,
        'Heuristic include resolution via current working directory: "' +
        State.TreeEdges[I].TargetDisplay + '"');

  Reported := 0;
  SetLength(SeenCalls, 0);
  for I := 0 to High(State.Routines) do
  begin
    R := State.Routines[I];
    for J := 0 to High(R.Calls) do
    begin
      CallName := Trim(R.Calls[J].Name);
      if Copy(CallName, 1, 5) = 'call ' then CallName := Trim(Copy(CallName, 6, MaxInt));
      P := Pos(':', CallName);
      if P > 0 then CallName := Trim(Copy(CallName, 1, P - 1));
      P := Pos(' ', CallName);
      if P > 0 then CallName := Trim(Copy(CallName, 1, P - 1));
      BasePos := LastDelimiter('.', CallName);
      if BasePos > 0 then Base := Copy(CallName, BasePos + 1, MaxInt) else Base := CallName;
      if (Base = '') or (Pos('.', CallName) > 0) or IsDeclaredSymbol(Base) or IsSysRoutineName(Base) then
        Continue;
      if Reported >= 100 then Break;
      DFile := R.FileIdx;
      DLine := R.StartLine;
      if Length(R.Calls[J].Sites) > 0 then
      begin
        DFile := R.Calls[J].Sites[0].FileIdx;
        DLine := R.Calls[J].Sites[0].Line;
      end;
      Key := IntToStr(DFile) + ':' + IntToStr(DLine) + ':' + LowerCase(CallName);
      S := 0;
      while (S <= High(SeenCalls)) and (SeenCalls[S] <> Key) do Inc(S);
      if S > High(SeenCalls) then
      begin
        SetLength(SeenCalls, Length(SeenCalls) + 1);
        SeenCalls[High(SeenCalls)] := Key;
        AddDiagnostic(DFile, DLine, 1, EXIT_BIT_WARNING,
          'Unresolved call to "' + CallName + '" in ' + R.Kind + ' ' + R.Name +
          ' (not declared in audited set and not a recognized built-in)');
        Inc(Reported);
      end;


    end;
    if Reported >= 100 then Break;
  end;
  if Reported >= 100 then
    AddDiagnostic(0, 1, 1, EXIT_BIT_WARNING,
      'Strict check: unresolved-call warnings truncated at 100');

  { Bare procedure calls without parentheses (e.g. MissingRoutine;) }
  for I := 0 to High(State.Files) do
  begin
    for J := 0 to High(State.Files[I].Tokens) - 1 do
    begin
      if State.Files[I].Tokens[J].Kind <> tkIdent then Continue;
      if IsPascalKeyword(State.Files[I].Tokens[J].Lower) then Continue;
      { only consider identifiers at statement position }
      if J = 0 then Continue;
      if not ((State.Files[I].Tokens[J-1].Text = ';') or
              (State.Files[I].Tokens[J-1].Lower = 'begin') or
              (State.Files[I].Tokens[J-1].Lower = 'then') or
              (State.Files[I].Tokens[J-1].Lower = 'do') or
              (State.Files[I].Tokens[J-1].Lower = 'else') or
              (State.Files[I].Tokens[J-1].Lower = 'repeat') or
              (State.Files[I].Tokens[J-1].Lower = 'try') or
              (State.Files[I].Tokens[J-1].Lower = 'finally') or
              (State.Files[I].Tokens[J-1].Lower = 'except') or
              (State.Files[I].Tokens[J-1].Lower = 'of')) then Continue;
      { only consider identifiers inside a routine body }
      InRoutine := False;
      for RR := 0 to High(State.Routines) do
        if (State.Routines[RR].FileIdx = I) and
           (State.Files[I].Tokens[J].Line >= State.Routines[RR].StartLine) and
           (State.Files[I].Tokens[J].Line <= State.Routines[RR].EndLine) then
        begin InRoutine := True; Break; end;
      if not InRoutine then Continue;
      { skip identifiers that follow a declaration keyword }
      if (State.Files[I].Tokens[J-1].Kind = tkIdent) then
      begin
        if IsPascalKeyword(State.Files[I].Tokens[J-1].Lower) and
           ((State.Files[I].Tokens[J-1].Lower = 'program') or
            (State.Files[I].Tokens[J-1].Lower = 'procedure') or
            (State.Files[I].Tokens[J-1].Lower = 'function') or
            (State.Files[I].Tokens[J-1].Lower = 'type') or
            (State.Files[I].Tokens[J-1].Lower = 'var') or
            (State.Files[I].Tokens[J-1].Lower = 'const') or
            (State.Files[I].Tokens[J-1].Lower = 'unit') or
            (State.Files[I].Tokens[J-1].Lower = 'library') or
            (State.Files[I].Tokens[J-1].Lower = 'constructor') or
            (State.Files[I].Tokens[J-1].Lower = 'destructor') or
            (State.Files[I].Tokens[J-1].Lower = 'property')) then
          Continue;
      end;
      { skip field/member accesses (preceded by '.') }
      if State.Files[I].Tokens[J-1].Text = '.' then Continue;
      if (J + 1 <= High(State.Files[I].Tokens)) then
      begin
        if State.Files[I].Tokens[J+1].Text = '(' then Continue;
        if State.Files[I].Tokens[J+1].Text = '.' then Continue;
        if State.Files[I].Tokens[J+1].Text = '[' then Continue;
        if State.Files[I].Tokens[J+1].Text = ':=' then Continue;
        if State.Files[I].Tokens[J+1].Text = ':' then Continue;
        if State.Files[I].Tokens[J+1].Text = '=' then Continue;
        { skip declaration lists like 'A, B: Integer;' }
        if State.Files[I].Tokens[J+1].Text = ',' then
        begin
          K := J + 1;
          while (K <= High(State.Files[I].Tokens)) and
                (State.Files[I].Tokens[K].Text <> ';') and
                (State.Files[I].Tokens[K].Text <> ':') do Inc(K);
          if (K <= High(State.Files[I].Tokens)) and
             (State.Files[I].Tokens[K].Text = ':') then Continue;
        end;
      end;
      CallName := State.Files[I].Tokens[J].Text;
      BasePos := LastDelimiter('.', CallName);
      if BasePos > 0 then Base := Copy(CallName, BasePos + 1, MaxInt) else Base := CallName;
      if (Base = '') or (Pos('.', CallName) > 0) or IsDeclaredRoutineName(Base) or IsSysRoutineName(Base) then Continue;
      if Reported >= 100 then Break;
      Key := IntToStr(I) + ':' + IntToStr(State.Files[I].Tokens[J].Line) + ':' + LowerCase(CallName);
      S := 0;
      while (S <= High(SeenCalls)) and (SeenCalls[S] <> Key) do Inc(S);
      if S > High(SeenCalls) then
      begin
        SetLength(SeenCalls, Length(SeenCalls) + 1);
        SeenCalls[High(SeenCalls)] := Key;
        AddDiagnostic(I, State.Files[I].Tokens[J].Line, State.Files[I].Tokens[J].Col,
          EXIT_BIT_WARNING,
          'Unresolved call to "' + CallName + '" (not declared in audited set and not a recognized built-in)');
        Inc(Reported);
      end;


    end;
    if Reported >= 100 then Break;
  end;

end;

function StripIncQuotes(const S: string): string;
begin
  Result := Trim(S);
  if Length(Result) >= 2 then
  begin
    if ((Result[1] = '''') and (Result[Length(Result)] = '''')) or
       ((Result[1] = '"') and (Result[Length(Result)] = '"')) then
      Result := Copy(Result, 2, Length(Result) - 2);
  end;
end;


function TryResolveIncCandidate(const BaseDir, CleanName: string): string;
var
  Cand: string;
begin
  Result := '';
  if CleanName = '' then Exit;
  if (BaseDir <> '') and (not (CleanName[1] in ['\', '/'])) and
     ((Length(CleanName) < 2) or (CleanName[2] <> ':')) then
    Cand := IncludeTrailingPathDelimiter(BaseDir) + CleanName
  else
    Cand := CleanName;
  if FileExists(Cand) then
    Exit(NormalizePath(Cand));
  if (ExtractFileExt(CleanName) = '') and FileExists(Cand + '.inc') then
    Exit(NormalizePath(Cand + '.inc'));
end;


function TypeHasSummary(const TD: TTypeDecl): string;
var
  I: Integer;
  FieldsS, PropsS, MethS, D, N, Tn: string;
  First: Boolean;

  procedure AddPart(var Acc: string; const Part: string; var IsFirst: Boolean);
  begin
    if Part = '' then Exit;
    if not IsFirst then Acc := Acc + ', ';
    Acc := Acc + Part;
    IsFirst := False;
  end;
begin
  Result := '';
  FieldsS := ''; PropsS := ''; MethS := '';
  First := True;
  for I := 0 to High(TD.Fields) do
  begin
    D := Trim(TD.Fields[I].Detail);
    if ExtractPropNameType(D, N, Tn) then
    begin
      if Tn <> '' then AddPart(PropsS, N + ' ' + Tn, First)
      else AddPart(PropsS, N, First);
    end
    else
    begin
      if D <> '' then AddPart(FieldsS, TD.Fields[I].Name + ' ' + D, First)
      else AddPart(FieldsS, TD.Fields[I].Name, First);
    end;
  end;
  { rebuild with separate first flags per section - simpler approach }
  FieldsS := ''; PropsS := ''; MethS := '';
  First := True;
  for I := 0 to High(TD.Fields) do
  begin
    D := Trim(TD.Fields[I].Detail);
    if ExtractPropNameType(D, N, Tn) then Continue;
    if D <> '' then AddPart(FieldsS, TD.Fields[I].Name + ':' + D, First)
    else AddPart(FieldsS, TD.Fields[I].Name, First);
  end;
  First := True;
  for I := 0 to High(TD.Fields) do
  begin
    D := Trim(TD.Fields[I].Detail);
    if not ExtractPropNameType(D, N, Tn) then Continue;
    if Tn <> '' then AddPart(PropsS, N + ':' + Tn, First)
    else AddPart(PropsS, N, First);
  end;
  First := True;
  for I := 0 to High(TD.Methods) do
    AddPart(MethS, ExtractMethodName(TD.Methods[I].Detail, TD.Methods[I].Name), First);

  Result := '';
  if FieldsS <> '' then Result := 'fields ' + FieldsS;
  if PropsS <> '' then
  begin
    if Result <> '' then Result := Result + '  ';
    Result := Result + 'props ' + PropsS;
  end;
  if MethS <> '' then
  begin
    if Result <> '' then Result := Result + '  ';
    Result := Result + 'methods ' + MethS;
  end;
end;

function UsageRefersToName(const UsageName, DeclName: string): Boolean;
var
  U, D: string;
  L: Integer;
begin
  U := Trim(UsageName);
  D := Trim(DeclName);
  Result := False;
  if (U = '') or (D = '') then Exit;
  L := Length(D);
  if Length(U) < L then Exit;
  if not SameText(Copy(U, 1, L), D) then Exit;
  if Length(U) = L then Exit(True);
  if U[L + 1] in [':', '.', '[', ' ', #9, ',', ')', ']', ';', '+', '-', '*', '/', '=', '<', '>', '@', '^'] then
    Result := True;
end;


function IsQuotedLiteral(const T: string): Boolean;
begin
  Result := (Length(T) >= 2) and ((T[1] = '''') or (T[1] = '"'));
end;


function IsNumericLiteralText(const T: string): Boolean;
var I: Integer; HasDot: Boolean;
begin
  Result := False;
  if T = '' then Exit;
  I := 1;
  if T[1] = '-' then Inc(I);
  if I > Length(T) then Exit;
  HasDot := False;
  while I <= Length(T) do
  begin
    if T[I] in ['0'..'9'] then
    begin
      Inc(I);
      Continue;
    end;
    if (T[I] = '.') and (not HasDot) then
    begin
      HasDot := True;
      Inc(I);
      Continue;
    end;
    Exit;
  end;
  Result := True;
end;


function TryExtractSimpleCall(const S: string; out Callee, ArgsS, Tail: string): Boolean;
var P, Depth, I: Integer; InStr: Boolean; C: Char;
begin
  Result := False;
  Callee := ''; ArgsS := ''; Tail := '';
  // Callee: identifier chars
  P := 1;
  if P > Length(S) then Exit;
  if not (S[P] in ['A'..'Z','a'..'z','_']) then Exit;
  while (P <= Length(S)) and (S[P] in ['A'..'Z','a'..'z','0'..'9','_','.']) do Inc(P);
  Callee := Copy(S, 1, P - 1);
  // skip spaces
  while (P <= Length(S)) and (S[P] in [' ', #9]) do Inc(P);
  if (P > Length(S)) or (S[P] <> '(') then Exit;
  Inc(P); // skip '('
  Depth := 1; InStr := False;
  I := P;
  while (I <= Length(S)) and (Depth > 0) do
  begin
    C := S[I];
    if InStr then
    begin
      if C = '''' then InStr := False;
      Inc(I);
      Continue;
    end;
    if C = '''' then
    begin
      InStr := True;
      Inc(I);
      Continue;
    end;
    if C = '(' then Inc(Depth)
    else if C = ')' then
    begin
      Dec(Depth);
      if Depth = 0 then Break;
    end;
    Inc(I);
  end;
  if Depth <> 0 then Exit;
  ArgsS := Copy(S, P, I - P);
  Inc(I); // skip ')'
  Tail := Trim(Copy(S, I, MaxInt));
  Result := True;
end;


function FormatFlowCallString(const Callee, ArgsS: string; CloseAsItem: Boolean): string;
begin
  Result := FlowCallHead(Callee) + ArgsS + ')';
end;


function FlowCallHead(const Callee: string): string;
begin
  Result := Callee + '(';
end;


function SplitTopLevelCSV(const S: string): TStringArray;
var I, Depth: Integer; InStr: Boolean; C: Char; Cur: string;
begin
  Result := nil;
  Cur := '';
  Depth := 0; InStr := False;
  I := 1;
  while I <= Length(S) do
  begin
    C := S[I];
    if InStr then
    begin
      Cur := Cur + C;
      if C = '''' then
      begin
        if (I < Length(S)) and (S[I+1] = '''') then
        begin
          Cur := Cur + S[I+1]; Inc(I);
        end
        else InStr := False;
      end;
      Inc(I); Continue;
    end;
    if C = '''' then
    begin
      InStr := True; Cur := Cur + C; Inc(I); Continue;
    end;
    if C = '(' then
    begin
      Inc(Depth); Cur := Cur + C; Inc(I); Continue;
    end;
    if C = ')' then
    begin
      Dec(Depth); Cur := Cur + C; Inc(I); Continue;
    end;
    if (C = ',') and (Depth = 0) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Trim(Cur);
      Cur := ''; Inc(I); Continue;
    end;
    Cur := Cur + C; Inc(I);
  end;
  if Trim(Cur) <> '' then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Trim(Cur);
  end;
end;



function IsDeclaredRoutineName(const Name: string): Boolean;
var I: Integer;
begin
  Result := False;
  for I := 0 to High(State.Routines) do
    if SameText(State.Routines[I].Name, Name) then
    begin
      Result := True;
      Exit;
    end;
end;

{ Built-in type names are recorded as "calls" by the parser when used as casts
  (e.g. Byte(X), UInt32(Y)). Recognize them so --strict does not flag them. }
function IsBuiltinTypeName(const L: string): Boolean;
begin
  Result :=
    { standard Pascal / FPC scalar types }
    (L = 'byte') or (L = 'shortint') or (L = 'smallint') or (L = 'word') or
    (L = 'integer') or (L = 'longint') or (L = 'longword') or (L = 'cardinal') or
    (L = 'int8') or (L = 'int16') or (L = 'int32') or (L = 'int64') or
    (L = 'uint8') or (L = 'uint16') or (L = 'uint32') or (L = 'uint64') or
    (L = 'qword') or (L = 'char') or (L = 'ansichar') or (L = 'widechar') or
    (L = 'boolean') or (L = 'bytebool') or (L = 'wordbool') or (L = 'longbool') or
    (L = 'single') or (L = 'double') or (L = 'extended') or (L = 'currency') or
    (L = 'real') or (L = 'real48') or (L = 'comp') or (L = 'pointer') or
    (L = 'string') or (L = 'ansistring') or (L = 'widestring') or
    (L = 'unicodestring') or (L = 'shortstring') or (L = 'variant');
end;

function IsSysRoutineName(const Name: string): Boolean;
var L: string;
begin
  L := LowerCase(Name);
  { type casts plus RTL methods/functions not enumerated in the chain below }
  if IsBuiltinTypeName(L) or
     (L = 'out') or (L = 'move') or (L = 'writebuffer') or (L = 'free') or
     (L = 'lastdelimiter') or (L = 'trystrtoint') or
     (L = 'posex') or (L = 'tfilestream') or (L = 'tsearchrec') or
     (L = 'tstringlist') or (L = 'tobject') or (L = 'tstream') then
  begin Result := True; Exit; end;


  Result :=
    { I/O, system }
    (L = 'writeln') or (L = 'write') or (L = 'readln') or (L = 'read') or
    (L = 'exit') or (L = 'halt') or (L = 'break') or (L = 'continue') or
    (L = 'inc') or (L = 'dec') or (L = 'ord') or (L = 'chr') or
    (L = 'succ') or (L = 'pred') or (L = 'low') or (L = 'high') or
    (L = 'sizeof') or (L = 'assigned') or (L = 'freeandnil') or
    (L = 'length') or (L = 'setlength') or (L = 'copy') or (L = 'pos') or
    (L = 'posx') or (L = 'delete') or (L = 'insert') or (L = 'concat') or
    (L = 'trim') or (L = 'uppercase') or (L = 'lowercase') or
    (L = 'sametext') or (L = 'comparetext') or (L = 'ansicomparetext') or
    { conversions }
    (L = 'inttostr') or (L = 'strtoint') or (L = 'strtointdef') or
    (L = 'inttohex') or (L = 'hex2dec') or (L = 'strtofloat') or (L = 'floattostr') or
    (L = 'str') or (L = 'val') or (L = 'round') or (L = 'trunc') or (L = 'frac') or
    (L = 'abs') or (L = 'sqr') or (L = 'sqrt') or (L = 'odd') or
    { strings }
    (L = 'format') or (L = 'formatdatetime') or (L = 'quotedstr') or
    (L = 'stringreplace') or (L = 'ansistringreplace') or (L = 'ansipos') or
    (L = 'ansicopy') or (L = 'ansiuppercase') or (L = 'ansilowercase') or
    (L = 'leftstr') or (L = 'rightstr') or (L = 'midstr') or
    (L = 'padl') or (L = 'padr') or
    { files }
    (L = 'fileexists') or (L = 'directoryexists') or (L = 'filegetattr') or
    (L = 'filesetattr') or (L = 'deletedfile') or (L = 'findfirst') or
    (L = 'findnext') or (L = 'findclose') or (L = 'sysutils.findclose') or
    (L = 'expandfilename') or (L = 'expandfilenametounix') or
    (L = 'includetrailingpathdelimiter') or (L = 'excludetrailingpathdelimiter') or
    (L = 'extractfilepath') or (L = 'extractfilename') or (L = 'extractfileext') or
    (L = 'extractfiledir') or (L = 'changefileext') or (L = 'createdir') or
    (L = 'forcedirectories') or (L = 'removedir') or (L = 'getcurrentdir') or
    (L = 'setcurrentdir') or (L = 'gettempdir') or (L = 'paramcount') or (L = 'paramstr') or
    (L = 'getenvironmentvariable') or (L = 'setenvironmentvariable') or
    { memory / objects }
    (L = 'getmem') or (L = 'freemem') or (L = 'reallocmem') or
    (L = 'new') or (L = 'dispose') or (L = 'movef') or (L = 'fillchar') or
    (L = 'comparemem') or (L = 'getmemorymanager') or
    { math }
    (L = 'max') or (L = 'min') or (L = 'arctan') or (L = 'sin') or (L = 'cos') or
    (L = 'power') or (L = 'exp') or (L = 'ln') or (L = 'random') or (L = 'randomize') or
    { misc }
    (L = 'assert') or (L = 'raise') or (L = 'except') or
    (L = 'gettickcount64') or (L = 'now') or (L = 'date') or (L = 'time') or
    (L = 'sleep') or (L = 'getdate') or (L = 'setdate') or
    (L = 'tfile.create') or (L = 'tstringlist.create') or (L = 'create');
end;

{ True if Name is any declared symbol: routine, var, param, local, type, global, forward }
function IsDeclaredSymbol(const Name: string): Boolean;
var I, J: Integer;
begin
  if IsDeclaredRoutineName(Name) then Exit(True);
  for I := 0 to High(State.Globals) do
    if SameText(State.Globals[I].Name, Name) then Exit(True);
  for I := 0 to High(State.Types) do
    if SameText(State.Types[I].Name, Name) then Exit(True);
  for I := 0 to High(State.Forwards) do
    if SameText(State.Forwards[I].Name, Name) then Exit(True);
  for I := 0 to High(State.Routines) do
  begin
    for J := 0 to High(State.Routines[I].Params) do
      if SameText(State.Routines[I].Params[J].Name, Name) then Exit(True);
    for J := 0 to High(State.Routines[I].Locals) do
      if SameText(State.Routines[I].Locals[J].Name, Name) then Exit(True);
    for J := 0 to High(State.Routines[I].Vars) do
      if SameText(State.Routines[I].Vars[J].Name, Name) then Exit(True);
  end;
  Result := False;
end;




function ExtractPropNameType(const D: string; out N, Tn: string): Boolean;
var P: Integer;
begin
  Result := False;
  N := ''; Tn := '';
  P := Pos(':', D);
  if P <= 0 then Exit;
  N := Trim(Copy(D, 1, P - 1));
  Tn := Trim(Copy(D, P + 1, MaxInt));
  Result := (N <> '');
end;

function ExtractMethodName(const Detail, Name: string): string;
begin
  if Detail <> '' then
    Result := Name + ' ' + Detail
  else
    Result := Name;
end;


{ Snapshot CLI flags into the pipeline options record. Called once, after
  command-line parsing, before any analyze/act/output stage runs. }
procedure LoadAppOptions;
begin
  Options.CheckOnly := CheckOnly;
  Options.StrictMode := StrictMode;
  Options.JsonMode := JsonMode;
  Options.SarifMode := SarifMode;
  Options.DiffMode := DiffMode;
  Options.DryRunMode := DryRunMode;
  Options.VerifyMode := VerifyMode;
  Options.FixForward := FixForward;
  Options.CheckForward := CheckForward;
  Options.FixAll := FixAll;
  Options.AddForward := AddForward;
  Options.AddInclude := AddInclude;
  Options.AddBlock := AddBlock;
  Options.ReadFullMode := ReadFullMode;
  Options.ReadFullLine := ReadFullLine;
  Options.FilterPattern := FilterPattern;
  Options.SearchInTarget := SearchInTarget;
  Options.ScopeBlockIdx := ScopeBlockIdx;
  Options.GetBlockMode := GetBlockMode;
  Options.GetBlockTarget := GetBlockTarget;
  Options.GetBlockWithOrigin := GetBlockWithOrigin;
  Options.GetBlockStandalone := GetBlockStandalone;
  Options.GlobalLinesMode := GlobalLinesMode;
  Options.GlobalLineMode := GlobalLineMode;
  Options.GlobalStmtsMode := GlobalStmtsMode;
  Options.LineToGSMode := LineToGSMode;
  Options.DecodeGSLineMode := DecodeGSLineMode;
  Options.GlobalLinesSpec := GlobalLinesSpec;
  Options.GlobalLineNum := GlobalLineNum;
  Options.OutFile := OutFile;
  Options.TargetFile := TargetFile;
  Options.OutlineMode := OutlineMode;
  Options.EditPlanTarget := EditPlanTarget;
  Options.EditPlanSpecified := EditPlanSpecified;
  Options.OutputRawMode := OutputRawMode;
  Options.InsertBeforeTarget := InsertBeforeTarget;
  Options.InsertAfterTarget := InsertAfterTarget;
  Options.InsertFilePath := InsertFilePath;
  Options.InsertFileBeforeTarget := InsertFileBeforeTarget;
  Options.InsertFileAfterTarget := InsertFileAfterTarget;
  Options.BeforeTarget := BeforeTarget;
  Options.AfterTarget := AfterTarget;
  Options.DeleteTarget := DeleteTarget;
  Options.ReplaceTarget := ReplaceTarget;
  Options.ReplaceText := ReplaceText;
  Options.InsertLoc := InsertLoc;
  Options.InsertText := InsertText;
  Options.DoDelete := DoDelete;
  Options.DoReplace := DoReplace;
  Options.DoInsert := DoInsert;
  Options.BlockEditMode := BlockEditMode;
  Options.BlockEditTarget := BlockEditTarget;
  Options.BlockEditMatch := BlockEditMatch;
  Options.BlockEditReplacement := BlockEditReplacement;
  Options.GlobalEditMode := GlobalEditMode;
  Options.GlobalDeleteMode := GlobalDeleteMode;
  Options.EditGLineMode := EditGLineMode;
  Options.DeleteGLineMode := DeleteGLineMode;
  Options.EditGLineNum := EditGLineNum;
  Options.EditFileIdx := EditFileIdx;
  Options.NoCacheMode := NoCacheMode;
  Options.ClearCacheMode := ClearCacheMode;
  Options.ShowByteOffsets := ShowByteOffsets;
  Options.LazarusProject := LazarusProject;
  Options.UnitsMode := UnitsMode;
  Options.ReportFilterSet := ReportFilterSet;
  Options.ReportOpts := ReportOpts;
  Options.FindPattern := FindPattern;
  Options.CallersTarget := CallersTarget;
  Options.OrphansMode := OrphansMode;
  Options.ShowRoutineTarget := ShowRoutineTarget;
  Options.LinesSliceSpec := LinesSliceSpec;
  Options.SearchPattern := SearchPattern;
  Options.GiveBlockNum := GiveBlockNum;
  Options.GiveBlockSpecified := GiveBlockSpecified;
  Options.BlockChunkSize := BlockChunkSize;
  Options.BlockSizeSpecified := BlockSizeSpecified;
  Options.WidenBlockSteps := WidenBlockSteps;
  Options.MaxTreeDepth := MaxTreeDepth;
  Options.HideVars := HideVars;
  Options.HideFuncs := HideFuncs;
  Options.HideBlocks := HideBlocks;
  Options.FixIndentMode := FixIndentMode;
  Options.IndentSize := IndentSize;
end;




{ Resolve a block-relative edit: find a unique token fragment inside the
  selected container, then turn it into a normal line-range replace edit so the
  existing --diff/--verify/write-back machinery applies. }
procedure ResolveBlockEdit;
var
  BM: TBlockMatch;
  B: TLogicBlock;
  Hits: TSearchHitArray;
  Scoped: TSearchHitArray;
  I, N, StartLn, EndLn: Integer;
begin
  if not BlockEditMode then Exit;
  if Trim(BlockEditMatch) = '' then
  begin
    WriteLn(ErrOutput, 'Block edit requires --match <fragment>');
    Halt(1);
  end;
  if Trim(BlockEditReplacement) = '' then
  begin
    WriteLn(ErrOutput, 'Block edit requires --with <replacement>');
    Halt(1);
  end;
  BM.BlockIdx := ResolveBlockTargetIndex(BlockEditTarget);
  if BM.BlockIdx < 0 then
  begin
    WriteLn(ErrOutput, 'Block edit target not found: ', BlockEditTarget);
    Halt(1);
  end;
  B := State.LogicBlocks[BM.BlockIdx];
  EditFileIdx := B.FileIdx;
  Hits := RunPascalTokenSearch(BlockEditMatch);
  Scoped := nil;
  N := 0;
  for I := 0 to High(Hits) do
    if (Hits[I].FileIdx = B.FileIdx) and
       (Hits[I].StartLine >= B.StartLine) and
       (Hits[I].EndLine <= B.EndLine) then
    begin
      SetLength(Scoped, N + 1);
      Scoped[N] := Hits[I];
      Inc(N);
    end;
  if N = 0 then
  begin
    WriteLn(ErrOutput, 'No match for "', BlockEditMatch, '" in block ', BlockEditTarget);
    Halt(1);
  end;
  if N > 1 then
  begin
    WriteLn(ErrOutput, 'Ambiguous block edit: ', N, ' matches for "',
      BlockEditMatch, '" in block ', BlockEditTarget, ' - refine --match');
    Halt(1);
  end;
  StartLn := Scoped[0].StartLine;
  EndLn := Scoped[0].EndLine;
  ReplaceTarget := IntToStr(StartLn) + '-' + IntToStr(EndLn);
  ReplaceText := StringReplace(BlockEditReplacement, '\n', LineEnding, [rfReplaceAll]);
  DoReplace := True;
  DoDelete := False;
  DoInsert := False;
end;

{ Collection-wide fragment edit: search every loaded/connected file, require a
  unique match, and write the edit back to the file that owns the match. }
procedure ResolveGlobalEdit;
var
  Hits: TSearchHitArray;
  N: Integer;
begin
  if (not GlobalEditMode) and (not GlobalDeleteMode) then Exit;
  if Trim(BlockEditMatch) = '' then
  begin
    WriteLn(ErrOutput, 'Global edit requires --match <fragment>');
    Halt(1);
  end;
  if GlobalEditMode and (Trim(BlockEditReplacement) = '') then
  begin
    WriteLn(ErrOutput, 'Global edit requires --with <replacement>');
    Halt(1);
  end;

  Hits := RunPascalTokenSearch(BlockEditMatch);
  if Trim(Options.SearchInTarget) <> '' then
    Hits := FilterSearchHitsByScope(Hits, Options.SearchInTarget);
  N := Length(Hits);
  if N = 0 then
  begin
    WriteLn(ErrOutput, 'No match for "', BlockEditMatch, '" in connected files');
    Halt(1);
  end;
  if N > 1 then
  begin
    WriteLn(ErrOutput, 'Ambiguous global edit: ', N, ' matches for "',
      BlockEditMatch, '" - refine --match or use --in <scope>');
    Halt(1);
  end;

  EditFileIdx := Hits[0].FileIdx;
  ReplaceTarget := IntToStr(Hits[0].StartLine) + '-' + IntToStr(Hits[0].EndLine);
  DeleteTarget := ReplaceTarget;
  if GlobalDeleteMode then
  begin
    DoDelete := True;
    DoReplace := False;
  end
  else
  begin
    ReplaceText := StringReplace(BlockEditReplacement, '\n', LineEnding, [rfReplaceAll]);
    DoReplace := True;
    DoDelete := False;
  end;
  DoInsert := False;
end;

{ Edit/delete a global line number by mapping it back to its owning file. }
procedure ResolveGlobalLineEdit;
var
  F, L: Integer;
begin
  if (not EditGLineMode) and (not DeleteGLineMode) then Exit;
  if (EditGLineNum < 1) or (EditGLineNum > Length(GFile)) then
  begin
    WriteLn(ErrOutput, 'Global line number out of range: ', EditGLineNum);
    Halt(1);
  end;
  if EditGLineMode and (Trim(BlockEditReplacement) = '') then
  begin
    WriteLn(ErrOutput, 'Global line edit requires --with <replacement>');
    Halt(1);
  end;
  F := GFile[EditGLineNum - 1];
  L := GLine[EditGLineNum - 1];
  EditFileIdx := F;
  ReplaceTarget := IntToStr(L) + '-' + IntToStr(L);
  DeleteTarget := ReplaceTarget;
  if DeleteGLineMode then
  begin
    DoDelete := True;
    DoReplace := False;
  end
  else
  begin
    ReplaceText := StringReplace(BlockEditReplacement, '\n', LineEnding, [rfReplaceAll]);
    DoReplace := True;
    DoDelete := False;
  end;
  DoInsert := False;
end;

{ Resolve a plain -delete/-replace target inside an --in scope. Symbolic targets
  are matched as unique token fragments within the container; explicit #id /
  line-range targets are validated against the container span. }
procedure ResolveScopedEditTarget;
var
  BM: TBlockMatch;
  B: TLogicBlock;
  Hits, Scoped: TSearchHitArray;
  I, N, StartLn, EndLn, Dummy: Integer;
  Target: string;
  IsExplicit: Boolean;
begin
  if Trim(Options.SearchInTarget) = '' then Exit;
  if not (DoDelete or DoReplace) then Exit;
  if BlockEditMode or GlobalEditMode or GlobalDeleteMode or
     EditGLineMode or DeleteGLineMode then Exit;

  BM := FindScopedBlockMatch(Options.SearchInTarget);
  if not BM.Found then
  begin
    WriteLn(ErrOutput, 'Edit scope target not found: ', Options.SearchInTarget);
    Halt(1);
  end;
  B := State.LogicBlocks[BM.BlockIdx];

  if DoDelete then Target := DeleteTarget else Target := ReplaceTarget;
  if Trim(Target) = '' then Exit;

  IsExplicit := (Copy(Target, 1, 1) = '#') or TryStrToInt(Target, Dummy);
  if (not IsExplicit) and (Pos('-', Target) > 0) then
    IsExplicit := TryStrToInt(Copy(Target, 1, Pos('-', Target) - 1), Dummy);

  if IsExplicit then
  begin
    if not ResolveTargetToLines(Target, False, StartLn, EndLn) then
    begin
      WriteLn(ErrOutput, 'Edit target not found: ', Target);
      Halt(1);
    end;
    if (StartLn < B.StartLine) or (EndLn > B.EndLine) then
    begin
      WriteLn(ErrOutput, 'Edit target outside --in scope: ', Target);
      Halt(1);
    end;
    EditFileIdx := B.FileIdx;
    Exit;
  end;

  Hits := RunPascalTokenSearch(Target);
  Scoped := nil;
  N := 0;
  for I := 0 to High(Hits) do
    if (Hits[I].FileIdx = B.FileIdx) and
       (Hits[I].StartLine >= B.StartLine) and
       (Hits[I].EndLine <= B.EndLine) then
    begin
      SetLength(Scoped, N + 1);
      Scoped[N] := Hits[I];
      Inc(N);
    end;
  if N = 0 then
  begin
    WriteLn(ErrOutput, 'No match for "', Target, '" in --in scope ', Options.SearchInTarget);
    Halt(1);
  end;
  if N > 1 then
  begin
    WriteLn(ErrOutput, 'Ambiguous edit target in --in scope: ', N,
      ' matches for "', Target, '"');
    Halt(1);
  end;
  EditFileIdx := B.FileIdx;
  ReplaceTarget := IntToStr(Scoped[0].StartLine) + '-' + IntToStr(Scoped[0].EndLine);
  DeleteTarget := ReplaceTarget;
end;

procedure ApplyFragmentEdit;
{ Replace only the matched token span on a line, preserving the rest of the
  line. Origin-aware: writes to the file that actually contains the target. }

var
  BIdx, FIdx, L, I, N, Col, EndCol: Integer;
  Hits: TSearchHitArray;
  Toks: TRawTokenArray;
  Lines, NewLines: TStringArray;
  LineText, Before, After, OutPath, S, TmpPath, TmpNorm: string;
  FS: TFileStream;
  TmpIdx, VCode: Integer;
  TmpCtx: TParseContext;
begin
  if Length(GStmts) = 0 then BuildGlobalStmtMap;
  N := FindGSSemanticPathIndex(FragTarget);
  if N > 0 then BIdx := GStmts[N - 1].BlockIdx else BIdx := ResolveBlockTargetIndex(FragTarget);
  if BIdx < 0 then
  begin
    WriteLn(ErrOutput, 'Fragment edit target not found: ', FragTarget);
    Halt(1);
  end;
  FIdx := State.LogicBlocks[BIdx].FileIdx;
  if (FIdx < 0) or (FIdx >= Length(State.Files)) then
  begin
    WriteLn(ErrOutput, 'Fragment edit file not available');
    Halt(1);
  end;
  Hits := RunPascalTokenSearch(FragMatch);
  N := 0;
  L := 0; Col := 0;
  for I := 0 to High(Hits) do
    if (Hits[I].FileIdx = FIdx) and
       (Hits[I].StartLine >= State.LogicBlocks[BIdx].StartLine) and
       (Hits[I].EndLine <= State.LogicBlocks[BIdx].EndLine) then
    begin
      Inc(N);
      L := Hits[I].StartLine;
      Col := Hits[I].Col;
    end;
  if N <> 1 then
  begin
    WriteLn(ErrOutput, 'Fragment edit match must be unique in target (', N,
      ' matches): ', FragMatch);
    Halt(1);
  end;
  Toks := State.Files[FIdx].Tokens;
  EndCol := 0;
  for I := 0 to High(Toks) do
    if (Toks[I].Line = L) and (Toks[I].Col = Col) then
    begin EndCol := Col + Length(Toks[I].Text); Break; end;
  if EndCol <= Col then
  begin
    WriteLn(ErrOutput, 'Fragment token not found at line ', L, ' col ', Col);
    Halt(1);
  end;
  Lines := State.Files[FIdx].Lines;
  if (L < 1) or (L > Length(Lines)) then
  begin
    WriteLn(ErrOutput, 'Fragment line out of range: ', L);
    Halt(1);
  end;
  LineText := Lines[L - 1];
  Before := Copy(LineText, 1, Col - 1);
  After := Copy(LineText, EndCol, MaxInt);
  NewLines := Copy(Lines, 0, MaxInt);
  NewLines[L - 1] := Before + FragWith + After;
  OutPath := State.Files[FIdx].FilePath;
  if Options.OutFile <> '' then OutPath := Options.OutFile;
  if Options.DiffMode or Options.DryRunMode then
  begin
    EmitUnifiedDiff(Lines, NewLines, OutPath);
    Halt(0);
  end;
  if Options.VerifyMode then
  begin
    TmpPath := OutPath + '.fpaudit.tmp';
    FS := TFileStream.Create(TmpPath, fmCreate);
    try
      for I := 0 to High(NewLines) do
      begin
        S := NewLines[I] + LineEnding;
        if Length(S) > 0 then FS.WriteBuffer(S[1], Length(S));
      end;
    finally
      FS.Free;
    end;
    TmpNorm := NormalizePath(TmpPath);
    TmpIdx := LoadAndLexFile(TmpNorm, TmpPath, -1, 0);
    if TmpIdx < 0 then
    begin
      WriteLn(ErrOutput, 'Verify failed: could not read temporary file');
      SysUtils.DeleteFile(TmpPath);
      Halt(1);
    end;
    FillChar(TmpCtx, SizeOf(TmpCtx), 0);
    TmpCtx.InInterface := False;
    TmpCtx.ActiveRoutineIdx := -1;
    TmpCtx.ActiveBlockIdx := -1;
    SetLength(TmpCtx.ActiveFiles, 1);
    TmpCtx.ActiveFiles[0] := TmpIdx;
    ParseFileTokens(TmpIdx, TmpCtx);
    VCode := ComputeExitCode;
    SysUtils.DeleteFile(TmpPath);
    if VCode <> 0 then
    begin
      WriteLn(ErrOutput, 'Verify FAILED: resulting source has exit code ', VCode,
        ' - edit NOT applied');
      Halt(1);
    end;
    WriteLn(Output, 'Verify OK: resulting source is clean');
  end;
  WriteLinesToFile(OutPath, NewLines);
  WriteLn(Output, 'Written: ', OutPath);
  Halt(0);
end;

procedure ApplyEdit(RootFileIdx: Integer);
begin
{ Apply edit operations: --delete, --replace, --insert }
if EditFileIdx < 0 then EditFileIdx := RootFileIdx;
if DoDelete or DoReplace or DoInsert then
begin
  { load file contents for --insert-file / --replace-file }
  SetLength(InsertLines, 0);
  if (InsertFilePath <> '') and FileExists(InsertFilePath) then
  begin
    ReadEntireFile(InsertFilePath, FileText);
    SplitSourceLines(FileText, InsertLines);
    if DoReplace then
    begin
      ReplaceText := '';
      for K := 0 to High(InsertLines) do
      begin
        { skip a trailing empty element produced by SplitSourceLines - adding
          LineEnding after it is what created the +1 blank line on every edit }
        if (K = High(InsertLines)) and (InsertLines[K] = '') then Break;
        if K > 0 then ReplaceText := ReplaceText + LineEnding;
        ReplaceText := ReplaceText + InsertLines[K];
      end;
    end;
  end;

  { resolve --insert-before / --insert-after (and insert-file-before/after) via helper }
  InsertAfterMode := False;
  if (InsertBeforeTarget <> '') or (Options.InsertAfterTarget <> '') or
     (InsertFileBeforeTarget <> '') or (InsertFileAfterTarget <> '') or
     (BeforeTarget <> '') or (AfterTarget <> '') then
  begin
    ResolvedTarget := InsertBeforeTarget;
    if InsertFileBeforeTarget <> '' then ResolvedTarget := InsertFileBeforeTarget;
    if BeforeTarget <> '' then ResolvedTarget := BeforeTarget;
    if Options.InsertAfterTarget <> '' then
    begin
      ResolvedTarget := Options.InsertAfterTarget;
      InsertAfterMode := True;
    end;
    if InsertFileAfterTarget <> '' then
    begin
      ResolvedTarget := InsertFileAfterTarget;
      InsertAfterMode := True;
    end;
    if AfterTarget <> '' then
    begin
      ResolvedTarget := AfterTarget;
      InsertAfterMode := True;
    end;
    if not ResolveTargetToLines(ResolvedTarget, InsertAfterMode, StartLn, EndLn) then
    begin
      WriteLn(ErrOutput, 'Insert target not found: ', ResolvedTarget);
      Halt(1);
    end;
    InsertLoc := IntToStr(StartLn);
  end;

  EditStartLine := 1;
  EditEndLine := 1;
  if DoDelete or DoReplace then
  begin
    if DoDelete then
    begin
      if not ResolveTargetToLines(DeleteTarget, False, StartLn, EndLn) then
      begin
        WriteLn(ErrOutput, 'Delete target not found: ', DeleteTarget);
        Halt(1);
      end;
    end
    else
    begin
      if not ResolveTargetToLines(ReplaceTarget, False, StartLn, EndLn) then
      begin
        WriteLn(ErrOutput, 'Replace target not found: ', ReplaceTarget);
        Halt(1);
      end;
    end;
    EditStartLine := StartLn;
    EditEndLine := EndLn;
    if (DoDelete or DoReplace) and (EditFileIdx >= 0) and (not SuppressLineWarn) then
    begin
      if DoDelete and (Pos('-', DeleteTarget) > 0) and
         (StrToIntDef(Copy(DeleteTarget, 1, Pos('-', DeleteTarget) - 1), 0) > 0) then
        WriteLn(ErrOutput, 'DEPRECATED: numeric line-range edit target "', DeleteTarget,
          '". Use -gsline <path> and -stmt-delete <path>, or -replace-fragment <container> <fragment> <text>.');
      if DoReplace and (Pos('-', ReplaceTarget) > 0) and
         (StrToIntDef(Copy(ReplaceTarget, 1, Pos('-', ReplaceTarget) - 1), 0) > 0) then
        WriteLn(ErrOutput, 'DEPRECATED: numeric line-range edit target "', ReplaceTarget,
          '". Use -gsline <path> and -stmt-replace <path>, or -replace-fragment <container> <fragment> <text>.');
    end;
    if DoDelete and (DeleteTarget <> '') and (Copy(DeleteTarget,1,1) <> '#') and (Pos('-', DeleteTarget) = 0) and (EndLn > StartLn) then
      WriteLn(ErrOutput, 'Warning: delete target "', DeleteTarget, '" resolves to block lines ', IntToStr(StartLn), '..', IntToStr(EndLn), ' (', IntToStr(EndLn - StartLn + 1), ' lines); the whole block will be deleted. Use --in <container>, #id, or an explicit start-end range.');
    if DoReplace and (ReplaceTarget <> '') and (Copy(ReplaceTarget,1,1) <> '#') and (Pos('-', ReplaceTarget) = 0) and (EndLn > StartLn) then
      WriteLn(ErrOutput, 'Warning: replace target "', ReplaceTarget, '" resolves to block lines ', IntToStr(StartLn), '..', IntToStr(EndLn), ' (', IntToStr(EndLn - StartLn + 1), ' lines); the whole block will be replaced. Use --in <container>, #id, or an explicit start-end range.');
  end;

{ Build new file content via helper }
  Lines := State.Files[EditFileIdx].Lines;
  NewLines := BuildEditedLines(Lines, EditStartLine, EditEndLine,
    DoDelete or DoReplace, DoReplace, ReplaceText);

  { Handle insert via helper }
  if DoInsert then
  begin
    if Length(InsertLines) = 0 then
    begin
      SetLength(InsertLines, 1);
      InsertLines[0] := Options.InsertText;
    end;
    InsertTextLines(NewLines, InsertLines, StrToIntDef(InsertLoc, 1));
  end;

  { --fix-forward: add forward declaration for inserted function/procedure }
  if Options.AddForward and (DoInsert or DoReplace) then
  begin
    InsertedText := '';
    if DoInsert then InsertedText := Options.InsertText;
    if DoReplace then InsertedText := ReplaceText;
    InsertedText := Trim(InsertedText);
    if (Copy(InsertedText, 1, 8) = 'function') or (Copy(InsertedText, 1, 9) = 'procedure') then
    begin
      { extract signature: first line up to ';' }
      SigEnd := Pos(';', InsertedText);
      if SigEnd > 0 then
      begin
        Sig := Copy(InsertedText, 1, SigEnd);
        FwdDecl := Sig + ' forward;';
        { find first function/procedure in NewLines and insert before it }
        for I := 0 to High(NewLines) do
        begin
          if (Copy(Trim(NewLines[I]), 1, 8) = 'function') or (Copy(Trim(NewLines[I]), 1, 9) = 'procedure') then
          begin
            { insert forward decl before this line }
            SetLength(NewLines, Length(NewLines) + 1);
            for J := Length(NewLines) - 1 downto I + 1 do
              NewLines[J] := NewLines[J - 1];
            NewLines[I] := FwdDecl;
            WriteLn(Output, 'Added forward declaration: ', FwdDecl);
            Break;
          end;
        end;
      end;
    end;
  end;

  { Write or diff: edits originating in an include file go back to that file }
  OutPath := Options.TargetFile;
  if EditFileIdx <> RootFileIdx then
    OutPath := State.Files[EditFileIdx].FilePath;
  if Options.OutFile <> '' then OutPath := Options.OutFile;

  { --verify: write to temp, parse, revert on failure }
  if Options.VerifyMode then
  begin
    TmpPath := OutPath + '.fpaudit.tmp';
    FS := TFileStream.Create(TmpPath, fmCreate);
    try
      for I := 0 to High(NewLines) do
      begin
        S := NewLines[I] + LineEnding;
        if Length(S) > 0 then FS.WriteBuffer(S[1], Length(S));
      end;
    finally
      FS.Free;
    end;
    TmpNorm := NormalizePath(TmpPath);
    TmpIdx := LoadAndLexFile(TmpNorm, TmpPath, -1, 0);
    if TmpIdx < 0 then
    begin
      WriteLn(ErrOutput, 'Verify failed: could not read temporary file');
      SysUtils.DeleteFile(TmpPath);
      Halt(1);
    end;
    FillChar(TmpCtx, SizeOf(TmpCtx), 0);
    TmpCtx.InInterface := False;
    TmpCtx.ActiveRoutineIdx := -1;
    TmpCtx.ActiveBlockIdx := -1;
    SetLength(TmpCtx.ActiveFiles, 1);
    TmpCtx.ActiveFiles[0] := TmpIdx;
    if EditFileIdx = RootFileIdx then
    begin
      ParseFileTokens(TmpIdx, TmpCtx);
      VCode := ComputeExitCode;
    end
    else
      VCode := 0; { include fragments are not standalone programs; lexical check only }
    SysUtils.DeleteFile(TmpPath);
    if VCode <> 0 then
    begin
      WriteLn(ErrOutput, 'Verify FAILED: resulting source has exit code ', VCode,
        ' - edit NOT applied');
      Halt(1);
    end;
    if EditFileIdx = RootFileIdx then
      WriteLn(Output, 'Verify OK: resulting source is clean')
    else
      WriteLn(Output, 'Verify OK: include source is lexically clean');
  end;

  if Options.DiffMode or Options.DryRunMode then
  begin
    EmitUnifiedDiff(Lines, NewLines, OutPath);
    Halt(0);
  end
  else
  begin
    WriteLinesToFile(OutPath, NewLines);
    WriteLn(Output, 'Written: ', OutPath);
  end;

  Halt(0);
end;
end;


{ A forward is only required when the routine is referenced before its
  implementation and no interface/forward declaration already made it visible. }
function ImplNeedsForward(const Name: string; ImplLine, FIdx: Integer): Boolean;
var
  Toks: TRawTokenArray;
  I, N: Integer;
  Low, Prev, Next: string;
  Declared: Boolean;
begin
  Result := False;
  Low := LowerCase(RoutineSimpleName(Name));
  if Low = '' then Exit;
  Declared := False;
  for I := 0 to High(State.Forwards) do
    if SameText(RoutineSimpleName(State.Forwards[I].Name), Low) then
    begin Declared := True; Break; end;
  if Declared then Exit;
  if (FIdx < 0) or (FIdx >= Length(State.Files)) then Exit;
  Toks := State.Files[FIdx].Tokens;
  N := Length(Toks);
  for I := 0 to N - 1 do
  begin
    if Toks[I].Line > ImplLine then Break;
    if LowerCase(Toks[I].Text) <> Low then Continue;
    if Toks[I].Line = ImplLine then Continue;
    Prev := '';
    if I > 0 then Prev := LowerCase(Toks[I - 1].Text);
    if (Prev = 'procedure') or (Prev = 'function') or (Prev = 'constructor') or
       (Prev = 'destructor') or (Prev = 'operator') then Continue;
    Next := '';
    if I + 1 < N then Next := Toks[I + 1].Text;
    if (Next = '(') or (Next = ';') or (Next = ',') or (Next = ')') or
       (Next = ':=') or (Prev = '@') then
    begin Result := True; Exit; end;
  end;
end;
procedure RunForwardStage;
begin
{ Forward declaration check / fix }
if Options.CheckForward or Options.FixForward or Options.FixAll then
begin
  Fwds := ScanForwardDecls(RootIdx);
  Impls := ScanImplementations(RootIdx);
  MatchForwards(Fwds, Impls);
  for I := 0 to High(Impls) do
    Impls[I].NeedsFwd := (not Impls[I].HasForward) and ImplNeedsForward(Impls[I].Name, Impls[I].LineNum, RootIdx);

  WriteLn(Output, '=== Forward declaration report ===');
  UsedCnt := 0; UnusedCnt := 0; AmbigCnt := 0; NeedCnt := 0; MismatchCnt := 0;

  for I := 0 to High(Fwds) do
  begin
    if Fwds[I].ImpCount = 0 then
    begin
      Inc(UnusedCnt);
      WriteLn(Output, 'UNUSED forward: ', Fwds[I].Name, ' at line ', Fwds[I].LineNum, ' (no implementation)');
    end
    else if Fwds[I].ImpCount > 1 then
    begin
      Inc(AmbigCnt);
      WriteLn(Output, 'AMBIGUOUS forward: ', Fwds[I].Name, ' at line ', Fwds[I].LineNum,
        ' (', Fwds[I].ImpCount, ' implementations)');
      for J := 0 to High(Impls) do
        if SameText(Fwds[I].Name, Impls[J].Name) then
          WriteLn(Output, '    candidate line ', Impls[J].LineNum, ': ', Impls[J].Signature);
    end
    else
    begin
      Inc(UsedCnt);
      if LowerCase(Fwds[I].Signature) <> LowerCase(Fwds[I].ImplSignature) then
      begin
        Inc(MismatchCnt);
        WriteLn(Output, 'MISMATCH forward: ', Fwds[I].Name, ' line ', Fwds[I].LineNum,
          ' != impl line ', Fwds[I].ImplLine);
      end
      else
        WriteLn(Output, 'USED forward: ', Fwds[I].Name, ' -> line ', Fwds[I].ImplLine);
    end;
  end;

  for I := 0 to High(Impls) do
    if Impls[I].NeedsFwd then
    begin
      Inc(NeedCnt);
      WriteLn(Output, 'NEEDS forward: ', Impls[I].Name, ' at line ', Impls[I].LineNum);
    end;

  WriteLn(Output, '');
  WriteLn(Output, 'Summary: used=', UsedCnt, ' unused=', UnusedCnt, ' ambiguous=', AmbigCnt,
    ' needs=', NeedCnt, ' mismatch=', MismatchCnt,
    ' forwards=', Length(Fwds), ' impls=', Length(Impls));

  if Options.FixForward or Options.FixAll then
  begin
    { Build fixed content: remove unused forwards, correct mismatches, add missing forwards }
    Lines := State.Files[RootIdx].Lines;
    NewLines := nil;
    SetLength(NewLines, 0);
    for I := 0 to High(Lines) do
    begin
      SkipLine := False;
      L := Trim(Lines[I]);
      if (Copy(L, 1, 8) = 'function') or (Copy(L, 1, 9) = 'procedure') then
        if Pos('forward;', LowerCase(L)) > 0 then
        begin
          FName := ExtractRoutineName(L);
          for J := 0 to High(Fwds) do
            if (Fwds[J].LineNum = I + 1) and (Fwds[J].ImpCount = 0) then
              SkipLine := True;
          { correct mismatch: replace forward with impl signature + forward; }
          if not SkipLine then
            for J := 0 to High(Fwds) do
              if (Fwds[J].LineNum = I + 1) and (Fwds[J].ImpCount = 1) and
                 (LowerCase(Fwds[J].Signature) <> LowerCase(Fwds[J].ImplSignature)) then
              begin
                SetLength(NewLines, Length(NewLines) + 1);
                NewLines[High(NewLines)] := Fwds[J].ImplSignature + '; forward;';
                SkipLine := True;
                WriteLn(Output, 'Fixed forward: ', Fwds[J].Name);
              end;
        end;
      if not SkipLine then
      begin
        SetLength(NewLines, Length(NewLines) + 1);
        NewLines[High(NewLines)] := Lines[I];
      end;
      { after an implementation that needs a forward, insert one before it }
      if (Copy(L, 1, 8) = 'function') or (Copy(L, 1, 9) = 'procedure') then
        if Pos('forward;', LowerCase(L)) = 0 then
        begin
          FName := ExtractRoutineName(L);
          for J := 0 to High(Impls) do
if (Impls[J].LineNum = I + 1) and Impls[J].NeedsFwd then
            begin
              { insert forward before impl: append now, then swap }
              SetLength(NewLines, Length(NewLines) + 1);
              { put forward before the impl we just added }
              NewLines[High(NewLines)] := Lines[I];
              FwdSig := Trim(ExtractRoutineSignature(L));
              if (FwdSig <> '') and (FwdSig[Length(FwdSig)] = ';') then
                SetLength(FwdSig, Length(FwdSig) - 1);
              NewLines[High(NewLines)-1] := FwdSig + '; forward;';
              WriteLn(Output, 'Added forward: ', FName);
            end;
        end;
    end;
    if Options.DryRunMode then
    begin
      EmitUnifiedDiff(Lines, NewLines, Options.TargetFile);
      WriteLn(Output, 'Dry run: forward fixes NOT applied');
    end
    else
    begin
      WriteLinesToFile(Options.TargetFile, NewLines);
      WriteLn(Output, 'Forward fixes written to: ', Options.TargetFile);
    end;
    Halt(0);
  end;

  if (UnusedCnt > 0) or (AmbigCnt > 0) or (NeedCnt > 0) or (MismatchCnt > 0) then
    Halt(2);
  Halt(0);
end;
end;


procedure EmitOutputStage;
var
  ReadFIdx, ReadLine, ScopeStart, ScopeEnd: Integer;
begin
ExitCode := ComputeExitCode;
if Options.ReadFullMode <> '' then
begin
  ReadFIdx := RootIdx;
  ReadLine := Options.ReadFullLine;
  if Options.ScopeBlockIdx >= 0 then
  begin
    ScopeStart := State.LogicBlocks[Options.ScopeBlockIdx].StartLine;
    ScopeEnd := State.LogicBlocks[Options.ScopeBlockIdx].EndLine;
    ReadFIdx := State.LogicBlocks[Options.ScopeBlockIdx].FileIdx;
    ReadLine := ScopeStart + Options.ReadFullLine - 1;
    if (ReadLine < ScopeStart) or (ReadLine > ScopeEnd) then
    begin
      WriteLn(ErrOutput, 'Read-full line outside --in scope: ', Options.ReadFullLine);
      Halt(1);
    end;
  end;
  EmitReadFull(ReadFIdx, ReadLine, Options.ReadFullMode, Options.AddInclude, Options.AddBlock);
  Halt(0);
end
else if Options.FilterPattern <> '' then
Write(BuildFilterReport)
else if Options.JsonMode then
Write(BuildJsonReport(ExitCode))
else if Options.SarifMode then
Write(BuildSarifReport(ExitCode))
else
Write(BuildTextReport(ExitCode));
Halt(ExitCode);
end;


begin
SetAllReportSections(ReportOpts, True);
TargetFile := '';
OutlineMode := False;
CheckOnly := False;
StrictMode := False;
EditPlanTarget := '';
EditPlanSpecified := False;
  CommentHead := -1;
  CommentTail := -1;
DiffMode := False;
FixForward := False;
CheckForward := False;
  AddForward := False;
  FixAll := False;
  OutputRawMode := False;
  InsertBeforeTarget := '';
  InsertAfterTarget := '';
  FilterPattern := '';
  ReadFullMode := '';
  ReadFullLine := 0;
  AddInclude := False;
  AddBlock := False;
  InsertFilePath := '';
  InsertFileBeforeTarget := '';
  InsertFileAfterTarget := '';
  BeforeTarget := '';
  AfterTarget := '';
  SetLength(InsertLines, 0);
  DryRunMode := False;
  LazarusProject := '';
  SetLength(UnitPaths, 0);
  UnitsMode := False;
  SetLength(UnitStack, 0);
  SetLength(ParsedUnits, 0);
DeleteTarget := '';
ReplaceTarget := '';
ReplaceText := '';
InsertLoc := '';
InsertText := '';
OutFile := '';
DoDelete := False;
DoReplace := False;
DoInsert := False;
VerifyMode := False; FixIndentMode := False; IndentSize := 2;

JsonMode := False;
SarifMode := False;
NoCacheMode := False;
ClearCacheMode := False;
CacheLoaded := False;
ShowByteOffsets := False;
ReportFilterSet := False;
FindPattern := '';
CallersTarget := '';
OrphansMode := False;
ShowRoutineTarget := '';
LinesSliceSpec := '';
SearchPattern := '';
SearchInTarget := '';
ScopeBlockIdx := -1;
GetBlockMode := False;
GetBlockTarget := '';
GetBlockWithOrigin := False;
GetBlockStandalone := False;
GlobalLinesMode := False;
GlobalLineMode := False;
GlobalStmtsMode := False;
LineToGSMode := False;
DecodeGSLineMode := False;
GlobalLinesSpec := '';
GlobalLineNum := 0;
EditGLineMode := False;
DeleteGLineMode := False;
EditGLineNum := 0;
SetLength(GStmts, 0);
SetLength(DefineNames, 0);
SetLength(GFile, 0);
SetLength(GLine, 0);
SetLength(GStmts, 0);
SetLength(EdgeLines, 0);
BlockEditMode := False;
BlockEditTarget := '';
BlockEditMatch := '';
  SuppressLineWarn := False;
BlockEditReplacement := '';
FragmentEditMode := False;
FragTarget := '';
FragMatch := '';
FragWith := '';
GlobalEditMode := False;
GlobalDeleteMode := False;
StmtListMode := False;
StmtListTarget := '';
StmtEditMode := False;
StmtEditTarget := '';
StmtEditIndex := 0;
StmtEditAction := '';
StmtEditText := '';

EditFileIdx := -1;
GiveBlockNum := 0;
GiveBlockSpecified := False;
BlockChunkSize := 128;
BlockSizeSpecified := False;
WidenBlockSteps := 0;
MaxTreeDepth := -1;
HideVars := False;
HideFuncs := False;
HideBlocks := False;

{ Pre-scan generic --before/--after modifiers }
I := 1;
while I <= ParamCount do
begin
  if (ParamStr(I) = '--before') and (I + 1 <= ParamCount) then
  begin
    BeforeTarget := ParamStr(I + 1);
    Inc(I);
  end
  else if (ParamStr(I) = '--after') and (I + 1 <= ParamCount) then
  begin
    AfterTarget := ParamStr(I + 1);
    Inc(I);
  end;
  Inc(I);
end;

I := 1;
while I <= ParamCount do
begin
Param := ParamStr(I);
if (Param = '-h') or (Param = '--help') or (Param = '-help') or (Param = '/help') or (Param = '-?') or (Param = '/?') then
begin
PrintHelp(Output);
Halt(0);
end
else if (Copy(Param, 1, 3) = '-Fi') and (Length(Param) > 3) then
begin
SetLength(IncPaths, Length(IncPaths) + 1);
IncPaths[High(IncPaths)] := Copy(Param, 4, MaxInt);
end
else if (Copy(Param, 1, 3) = '-Fu') and (Length(Param) > 3) then
begin
SetLength(UnitPaths, Length(UnitPaths) + 1);
UnitPaths[High(UnitPaths)] := Copy(Param, 4, MaxInt);
UnitsMode := True;
end
else if Param = '--units' then
UnitsMode := True
else if (Copy(Param, 1, 8) = '/report:') or (Copy(Param, 1, 8) = '-report:') or
        (Copy(Param, 1, 9) = '--report=') or (Copy(Param, 1, 8) = '-report=') or (Copy(Param, 1, 8) = '/report=') then
begin
if Copy(Param, 1, 9) = '--report=' then
  Spec := Copy(Param, 10, MaxInt)
else if (Copy(Param, 1, 8) = '/report:') or (Copy(Param, 1, 8) = '-report:') then
  Spec := Copy(Param, 9, MaxInt)
else
  Spec := Copy(Param, 9, MaxInt);
if not ParseReportFilter(Spec, ReportOpts, BadTok) then
begin
WriteLn(ErrOutput, 'Unknown report section: ', BadTok);
WriteLn(ErrOutput, '');
PrintHelp(ErrOutput);
Halt(1);
end;
end
else if (Param = '-outline') or (Param = '/outline') or (Param = '--outline') then
  OutlineMode := True
else if (Param = '-check') or (Param = '/check') or (Param = '--check') then
  CheckOnly := True
else if (Param = '-orphans') or (Param = '/orphans') or (Param = '--orphans') then
    OrphansMode := True
else if Param = '--strict' then
  StrictMode := True
else if (Param = '-version') or (Param = '/version') or (Param = '--version') then
begin
  WriteLn(Output, 'fpctools ', FPCAUDIT_VERSION, ' (parser ', FPCAUDIT_PARSER_VERSION, ')');
  Halt(0);
end
else if (Param = '-schema-version') or (Param = '/schema-version') or (Param = '--schema-version') then
begin
  WriteLn(Output, JSON_SCHEMA_VERSION);
  Halt(0);
end
else if (Param = '-edit-plan') or (Param = '/edit-plan') or (Param = '--edit-plan') then
begin
  if I + 1 <= ParamCount then
  begin
    Inc(I);
    EditPlanTarget := ParamStr(I);
    EditPlanSpecified := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing value for --edit-plan');
    Halt(1);
  end;
end
else if (Param = '-edit-block') or (Param = '/edit-block') or (Param = '--edit-block') then
begin
  if I + 1 <= ParamCount then
  begin
    Inc(I);
    BlockEditTarget := ParamStr(I);
    BlockEditMode := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing value for -edit-block');
    Halt(1);
  end;
end
else if (Param = '-edit-global') or (Param = '/edit-global') or (Param = '--edit-global') then
GlobalEditMode := True
else if (Param = '-delete-global') or (Param = '/delete-global') or (Param = '--delete-global') then
GlobalDeleteMode := True
else if (Param = '-get-block') or (Param = '/get-block') or (Param = '--get-block') then
begin
  if I + 1 <= ParamCount then
  begin
    Inc(I);
    GetBlockTarget := ParamStr(I);
    GetBlockMode := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing value for -get-block');
    Halt(1);
  end;
end
else if (Param = '-stmts') or (Param = '/stmts') or (Param = '--stmts') or (Param = '-list-stmts') or (Param = '--list-stmts') then
begin
  if I + 1 <= ParamCount then
  begin
    Inc(I);
    StmtListTarget := ParamStr(I);
    StmtListMode := True;
  end
  else begin WriteLn(ErrOutput, 'Missing value for -stmts'); Halt(1); end;
end
else if IsCmd(Param, 'stmt-replace') then
begin
  if (I + 2 <= ParamCount) and IsGSPrefix(ParamStr(I + 1)) then
  begin
    Inc(I); StmtEditTarget := ParamStr(I);
    StmtEditIndex := 0;
    Inc(I); StmtEditText := ParamStr(I);
    StmtEditAction := 'replace'; StmtEditMode := True;
  end
  else if I + 3 <= ParamCount then
  begin
    Inc(I); StmtEditTarget := ParamStr(I);
    Inc(I); StmtEditIndex := StrToIntDef(ParamStr(I), 0);
    Inc(I); StmtEditText := ParamStr(I);
    StmtEditAction := 'replace'; StmtEditMode := True;
  end
  else begin WriteLn(ErrOutput, 'Usage: -stmt-replace <block> <index> <text> | -stmt-replace GS<n> <text>'); Halt(1); end;
end
else if IsCmd(Param, 'stmt-delete') then
begin
  if (I + 1 <= ParamCount) and IsGSPrefix(ParamStr(I + 1)) then
  begin
    Inc(I); StmtEditTarget := ParamStr(I);
    StmtEditIndex := 0;
    StmtEditText := ''; StmtEditAction := 'delete'; StmtEditMode := True;
  end
  else if I + 2 <= ParamCount then
  begin
    Inc(I); StmtEditTarget := ParamStr(I);
    Inc(I); StmtEditIndex := StrToIntDef(ParamStr(I), 0);
    StmtEditText := ''; StmtEditAction := 'delete'; StmtEditMode := True;
  end
  else begin WriteLn(ErrOutput, 'Usage: -stmt-delete <block> <index> | -stmt-delete GS<n>'); Halt(1); end;
end
else if IsCmd(Param, 'stmt-insert-before') then
begin
  if (I + 2 <= ParamCount) and IsGSPrefix(ParamStr(I + 1)) then
  begin
    Inc(I); StmtEditTarget := ParamStr(I);
    StmtEditIndex := 0;
    Inc(I); StmtEditText := ParamStr(I);
    StmtEditAction := 'insert-before'; StmtEditMode := True;
  end
  else if I + 3 <= ParamCount then
  begin
    Inc(I); StmtEditTarget := ParamStr(I);
    Inc(I); StmtEditIndex := StrToIntDef(ParamStr(I), 0);
    Inc(I); StmtEditText := ParamStr(I);
    StmtEditAction := 'insert-before'; StmtEditMode := True;
  end
  else begin WriteLn(ErrOutput, 'Usage: -stmt-insert-before <block> <index> <text> | -stmt-insert-before GS<n> <text>'); Halt(1); end;
end
else if IsCmd(Param, 'stmt-insert-after') then
begin
  if (I + 2 <= ParamCount) and IsGSPrefix(ParamStr(I + 1)) then
  begin
    Inc(I); StmtEditTarget := ParamStr(I);
    StmtEditIndex := 0;
    Inc(I); StmtEditText := ParamStr(I);
    StmtEditAction := 'insert-after'; StmtEditMode := True;
  end
  else if I + 3 <= ParamCount then
  begin
    Inc(I); StmtEditTarget := ParamStr(I);
    Inc(I); StmtEditIndex := StrToIntDef(ParamStr(I), 0);
    Inc(I); StmtEditText := ParamStr(I);
    StmtEditAction := 'insert-after'; StmtEditMode := True;
  end
  else begin WriteLn(ErrOutput, 'Usage: -stmt-insert-after <block> <index> <text> | -stmt-insert-after GS<n> <text>'); Halt(1); end;
end
else if Param = '--diff' then

begin
  DiffMode := True;
end
else if (Param = '-fix-forward') or (Param = '/fix-forward') or (Param = '--fix-forward') then
  FixForward := True
else if Param = '--add-forward' then
  AddForward := True
else if (Param = '-fix-all') or (Param = '/fix-all') or (Param = '--fix-all') then
  FixAll := True
else if Param = '--dry-run' then
  DryRunMode := True
else if (Param = '--before') or (Param = '--after') then
begin
  { already pre-scanned; skip the target value too }
  if I + 1 <= ParamCount then Inc(I);
end
else if (Param = '-filter') or (Param = '/filter') or (Param = '--filter') then
begin
  if I + 1 <= ParamCount then
  begin
    Inc(I);
    FilterPattern := ParamStr(I);
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing value for --filter');
    Halt(1);
  end;
end
else if (Param = '-read-full') or (Param = '/read-full') or (Param = '--read-full') then
begin
  if I + 2 <= ParamCount then
  begin
    Inc(I);
    ReadFullMode := LowerCase(ParamStr(I));
    Inc(I);
    ReadFullLine := StrToIntDef(ParamStr(I), 0);
  end
  else
  begin
    WriteLn(ErrOutput, 'Usage: -read-full <statement|block|line> <line>');
    Halt(1);
  end;
end
else if Param = '--add-include' then
  AddInclude := True
else if Param = '--add-block' then
  AddBlock := True
else if Param = '--output-raw' then
  OutputRawMode := True
else if Param = '--before' then
begin
  if I + 1 <= ParamCount then
  begin
    Inc(I);
    BeforeTarget := ParamStr(I);
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing value for --before');
    Halt(1);
  end;
end
else if Param = '--after' then
begin
  if I + 1 <= ParamCount then
  begin
    Inc(I);
    AfterTarget := ParamStr(I);
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing value for --after');
    Halt(1);
  end;
end
else if (Param = '-insert-before') or (Param = '/insert-before') or (Param = '--insert-before') then
begin
  if I + 2 <= ParamCount then
  begin
    Inc(I);
    InsertBeforeTarget := ParamStr(I);
    Inc(I);
    InsertText := ParamStr(I);
    DoInsert := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing values for --insert-before');
    Halt(1);
  end;
end
else if (Param = '-insert-after') or (Param = '/insert-after') or (Param = '--insert-after') then
begin
  if I + 2 <= ParamCount then
  begin
    Inc(I);
    InsertAfterTarget := ParamStr(I);
    Inc(I);
    InsertText := ParamStr(I);
    DoInsert := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing values for --insert-after');
    Halt(1);
  end;
end
else if (Param = '-insert-file') or (Param = '/insert-file') or (Param = '--insert-file') then
begin
  if (BeforeTarget <> '') or (AfterTarget <> '') then
  begin
    { syntax: --insert-file --before <t> <path>  -- skip modifier and value }
    if (ParamStr(I + 1) = '--before') or (ParamStr(I + 1) = '--after') then
      Inc(I, 2);
    if I + 1 <= ParamCount then
    begin
      Inc(I);
      InsertFilePath := ParamStr(I);
      if BeforeTarget <> '' then InsertFileBeforeTarget := BeforeTarget;
      if AfterTarget <> '' then InsertFileAfterTarget := AfterTarget;
      DoInsert := True;
    end
    else
    begin
      WriteLn(ErrOutput, 'Missing value for --insert-file');
      Halt(1);
    end;
  end
  else if I + 2 <= ParamCount then
  begin
    Inc(I);
    InsertFileBeforeTarget := ParamStr(I);
    Inc(I);
    InsertFilePath := ParamStr(I);
    DoInsert := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing values for --insert-file');
    Halt(1);
  end;
end
else if (Param = '-insert-file-before') or (Param = '/insert-file-before') or (Param = '--insert-file-before') then
begin
  if I + 2 <= ParamCount then
  begin
    Inc(I);
    InsertFileBeforeTarget := ParamStr(I);
    Inc(I);
    InsertFilePath := ParamStr(I);
    DoInsert := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing values for --insert-file-before');
    Halt(1);
  end;
end
else if (Param = '-insert-file-after') or (Param = '/insert-file-after') or (Param = '--insert-file-after') then
begin
  if I + 2 <= ParamCount then
  begin
    Inc(I);
    InsertFileAfterTarget := ParamStr(I);
    Inc(I);
    InsertFilePath := ParamStr(I);
    DoInsert := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing values for --insert-file-after');
    Halt(1);
  end;
end
else if (Param = '-replace-file') or (Param = '/replace-file') or (Param = '--replace-file') then
begin
  if I + 2 <= ParamCount then
  begin
    Inc(I);
    ReplaceTarget := ParamStr(I);
    Inc(I);
    InsertFilePath := ParamStr(I);
    DoReplace := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing values for --replace-file');
    Halt(1);
  end;
end
else if (Param = '-check-forward') or (Param = '/check-forward') or (Param = '--check-forward') then
  CheckForward := True
else if (Param = '--lazarus') or (Param = '-Fl') then
begin
  if I + 1 <= ParamCount then
  begin
    Inc(I);
    LazarusProject := ParamStr(I);
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing value for --lazarus');
    Halt(1);
  end;
end
else if (Param = '-delete') or (Param = '/delete') or (Param = '--delete') then
begin
  if I + 1 <= ParamCount then
  begin
    Inc(I);
    DeleteTarget := ParamStr(I);
    DoDelete := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing value for --delete');
    Halt(1);
  end;
end
else if (Param = '-replace') or (Param = '/replace') or (Param = '--replace') then
begin
  if I + 2 <= ParamCount then
  begin
    Inc(I);
    ReplaceTarget := ParamStr(I);
    Inc(I);
    ReplaceText := ParamStr(I);
    if LooksLikePascalFilePath(ReplaceText) then
    begin
      WriteLn(ErrOutput, 'A file path was supplied as replacement text. Use -replace-file <target> <path> instead.');
      Halt(1);
    end;
    DoReplace := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing values for --replace');
    Halt(1);
  end;
end
else if (Param = '-replace-fragment') or (Param = '/replace-fragment') or
        (Param = '--replace-fragment') then
begin
  if I + 3 <= ParamCount then
  begin
    Inc(I); FragTarget := ParamStr(I);
    Inc(I); FragMatch := ParamStr(I);
    Inc(I); FragWith := ParamStr(I);
    FragmentEditMode := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Usage: -replace-fragment <block> <fragment> <text>');
    Halt(1);
  end;
end
else if (Param = '-insert') or (Param = '/insert') or (Param = '--insert') then
begin
  if (BeforeTarget <> '') or (AfterTarget <> '') then
  begin
    { syntax: --insert --before <t> "text"  -- skip the --before/--after modifier and its value }
    if (ParamStr(I + 1) = '--before') or (ParamStr(I + 1) = '--after') then
      Inc(I, 2);
    if I + 1 <= ParamCount then
    begin
      Inc(I);
      InsertText := ParamStr(I);
    if LooksLikePascalFilePath(InsertText) then
    begin
      WriteLn(ErrOutput, 'A file path was supplied as inline text. Use -insert-file <target> <path> instead.');
      Halt(1);
    end;
      if BeforeTarget <> '' then InsertBeforeTarget := BeforeTarget;
      if AfterTarget <> '' then InsertAfterTarget := AfterTarget;
      DoInsert := True;
    end
    else
    begin
      WriteLn(ErrOutput, 'Missing value for --insert');
      Halt(1);
    end;
  end
  else if I + 2 <= ParamCount then
  begin
    Inc(I);
    InsertBeforeTarget := ParamStr(I);
    Inc(I);
    InsertText := ParamStr(I);
    if LooksLikePascalFilePath(InsertText) then
    begin
      WriteLn(ErrOutput, 'A file path was supplied as inline text. Use -insert-file <target> <path> instead.');
      Halt(1);
    end;
    DoInsert := True;
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing values for --insert');
    Halt(1);
  end;
end
else if Param = '--verify' then
  VerifyMode := True
else if (Param = '--outinsert') or (Param = '-outinsert') then
begin
  if I + 1 <= ParamCount then
  begin
    Inc(I);
    OutFile := ParamStr(I);
  end
  else
  begin
    WriteLn(ErrOutput, 'Missing value for --outinsert');
    Halt(1);
  end;
end
else if Param = '--format:sarif' then
SarifMode := True
else if (Param = '--format:json') or (Param = '--json') then
JsonMode := True
else if Param = '--no-cache' then
NoCacheMode := True
else if Param = '--fix-indent' then
  begin FixIndentMode := True; NoCacheMode := True; end

else if TryParseCliValueOpt(Param, '--indent-size', I, OptVal) then
  IndentSize := MaxIntVal(1, StrToIntDef(Trim(OptVal), 2))
else if Param = '--clear-cache' then
ClearCacheMode := True
else if (Param = '-block-tree') or (Param = '/block-tree') or (Param = '--block-tree') or
        (Param = '-logic-tree') or (Param = '/logic-tree') or (Param = '--logic-tree') then
begin
if not ReportFilterSet then
begin
SetAllReportSections(ReportOpts, False);
ReportFilterSet := True;
end;
ReportOpts.ShowBlockTree := True;
end
else if Param = '--no-vars' then
begin
HideVars := True;
ReportOpts.ShowVars := False;
end
else if (Param = '--no-funcs') or (Param = '--no-routines') then
begin
HideFuncs := True;
ReportOpts.ShowRoutines := False;
end
else if Param = '--no-blocks' then
HideBlocks := True
else if Param = '--no-assigns' then
ReportOpts.ShowAssigns := False
else if Param = '--no-calls' then
ReportOpts.ShowCalls := False
else if Param = '--no-types' then
ReportOpts.ShowTypes := False
else if Param = '--no-globals' then
ReportOpts.ShowGlobals := False
else if Param = '--no-forwards' then
ReportOpts.ShowForwards := False
else if Param = '--no-files' then
ReportOpts.ShowFiles := False
else if Param = '--no-tree' then
ReportOpts.ShowTree := False
else if Param = '--no-block-tree' then
ReportOpts.ShowBlockTree := False
else if Param = '--no-diag' then
ReportOpts.ShowDiag := False
else if TryParseCliValueOpt(Param, '--max-depth', I, OptVal) then
MaxTreeDepth := StrToIntDef(Trim(OptVal), -1)
else if TryParseCliValueOpt(Param, '--find', I, FindPattern) then begin end
else if TryParseCliValueOpt(Param, '--callers', I, CallersTarget) then begin end
else if TryParseCliValueOpt(Param, '--show', I, ShowRoutineTarget) then begin end
else if TryParseCliValueOpt(Param, '--lines', I, LinesSliceSpec) then begin end
else if TryParseCliValueOpt(Param, '--search', I, SearchPattern) then begin end
else if TryParseCliValueOpt(Param, '--in', I, SearchInTarget) then begin end
else if TryParseCliValueOpt(Param, '--match', I, BlockEditMatch) then begin end
else if TryParseCliValueOpt(Param, '--with', I, BlockEditReplacement) then begin end
else if Param = '--with-origin' then GetBlockWithOrigin := True
else if Param = '--standalone' then GetBlockStandalone := True
else if TryParseCliValueOpt(Param, '--glines', I, GlobalLinesSpec) then
begin
  GlobalLinesMode := True;
  WriteLn(ErrOutput, 'DEPRECATED: -glines/-gline are physical line views; prefer -gsline for per-statement resolution. Convert a compiler line number with -gline-to-gsline <n>.');

end
else if TryParseCliValueOpt(Param, '--gslines', I, OptVal) then
begin
  GlobalLinesSpec := Trim(OptVal);
  GlobalStmtsMode := True;
end
else if (Param = '--gsline') or (Param = '-gsline') or (Param = '/gsline') then
begin
  GlobalStmtsMode := True;
  { A selector is a following token that is neither a flag nor a source file. }
  if (I + 1 <= ParamCount) and (Copy(ParamStr(I + 1), 1, 1) <> '-') and
     (Pos('.pas', LowerCase(ParamStr(I + 1))) = 0) and
     (Pos('.pp', LowerCase(ParamStr(I + 1))) = 0) and
     (Pos('.inc', LowerCase(ParamStr(I + 1))) = 0) then
  begin
    Inc(I);
    OptVal := ParamStr(I);
    if Pos('-', OptVal) > 0 then
      GlobalLinesSpec := Trim(OptVal)
    else
    begin
      GSPathArg := Trim(OptVal);
      GlobalLineNum := StrToIntDef(Trim(OptVal), 0);
      GlobalLineMode := True;
    end;
  end
  else
    GlobalLinesSpec := '1-2147483647';
end
else if TryParseCliValueOpt(Param, '--gline-to-gsline', I, OptVal) or
        TryParseCliValueOpt(Param, '--gline2gs', I, OptVal) then
begin
  GlobalLineNum := StrToIntDef(Trim(OptVal), 0);
  LineToGSMode := True;
end
else if TryParseCliValueOpt(Param, '--decode-gsline', I, OptVal) then
begin
  GSPathArg := Trim(OptVal);
  GlobalLineNum := StrToIntDef(Trim(OptVal), 0);
  DecodeGSLineMode := True;
  GlobalStmtsMode := True;
end
else if TryParseCliValueOpt(Param, '--gline', I, OptVal) then
begin
  GlobalLineNum := StrToIntDef(Trim(OptVal), 0);
  GlobalLineMode := True;
  WriteLn(ErrOutput, 'DEPRECATED: -glines/-gline are physical line views; prefer -gsline for per-statement resolution. Convert a compiler line number with -gline-to-gsline <n>.');

end
else if TryParseCliValueOpt(Param, '--edit-gline', I, OptVal) then
begin
  EditGLineNum := StrToIntDef(Trim(OptVal), 0);
  EditGLineMode := True;
  WriteLn(ErrOutput, 'DEPRECATED: line-number edits shift after every write; use -gsline <path> and -stmt-replace <path> ... . Convert a compiler line number with -gline-to-gsline <n>.');

end
else if TryParseCliValueOpt(Param, '--delete-gline', I, OptVal) then
begin
  EditGLineNum := StrToIntDef(Trim(OptVal), 0);
  DeleteGLineMode := True;
  WriteLn(ErrOutput, 'DEPRECATED: line-number edits shift after every write; use -gsline <path> and -stmt-replace <path> ... . Convert a compiler line number with -gline-to-gsline <n>.');

end
else if TryParseCliValueOpt(Param, '--give-block', I, OptVal) or
TryParseCliValueOpt(Param, '--chunk', I, OptVal) then
begin
GiveBlockSpecified := True;
GiveBlockNum := MaxIntVal(1, StrToIntDef(Trim(OptVal), 1));
end
else if TryParseCliValueOpt(Param, '--block-size', I, OptVal) or
TryParseCliValueOpt(Param, '--chunk-size', I, OptVal) then
begin
BlockSizeSpecified := True;
BlockChunkSize := MaxIntVal(1, StrToIntDef(Trim(OptVal), 128));
end
else if (Param = '--widen') or (Param = '--back-block') or (Param = '--parent-block') then
Inc(WidenBlockSteps)
else if TryParseCliValueOpt(Param, '--widen', I, OptVal) or
TryParseCliValueOpt(Param, '--back-block', I, OptVal) then
Inc(WidenBlockSteps, MaxIntVal(1, StrToIntDef(Trim(OptVal), 1)))
else if (Param <> '') and ((Param[1] = '-') or (Param[1] = '/')) then
begin
WriteLn(ErrOutput, 'Unknown option: ', Param);
WriteLn(ErrOutput, '');
PrintHelp(ErrOutput);
Halt(1);
end
else if TargetFile = '' then
TargetFile := Param;
Inc(I);
end;
if TargetFile = '' then
begin
PrintHelp(ErrOutput);
Halt(1);
end;

if not FileExists(TargetFile) then
begin
WriteLn(ErrOutput, 'File not found: ', TargetFile);
Halt(1);
end;

  if Options.OutlineMode and (not ReportFilterSet) then
begin
SetAllReportSections(ReportOpts, False);
ReportOpts.ShowTree := True;
ReportOpts.ShowBlockTree := True;
ReportOpts.ShowDiag := True;
ReportOpts.ShowFiles := True;
ReportOpts.ShowTypes := True;
ReportOpts.ShowGlobals := True;
ReportOpts.ShowForwards := True;
ReportOpts.ShowRoutines := True;
end;

if CheckOnly and (not ReportFilterSet) then
begin
SetAllReportSections(ReportOpts, False);
ReportOpts.ShowDiag := True;
end;

if ClearCacheMode and FileExists(GetCacheFilePath) then
DeleteFile(GetCacheFilePath);

LazarusProjectFiles := nil;
if LazarusProject <> '' then
  begin
    SetLength(LazarusProjectFiles, Length(LazarusProjectFiles) + 1);
    LazarusProjectFiles[High(LazarusProjectFiles)] := LazarusProject;
    AutoLoadLazarusProjectPaths;
  end;
LoadAppOptions;
if (not Options.ClearCacheMode) and (not Options.FixIndentMode) and TryLoadAuditCache then
  CacheLoaded := True
else
begin
  RootNorm := NormalizePath(Options.TargetFile);
  RootIdx := LoadAndLexFile(RootNorm, Options.TargetFile, -1, 0);
  if RootIdx < 0 then
  begin
    WriteLn(ErrOutput, 'Failed to read file: ', Options.TargetFile);
    Halt(1);
  end;

  RootCtx.InInterface := False;
  RootCtx.ActiveRoutineIdx := -1;
  RootCtx.ActiveBlockIdx := -1;
  SetLength(RootCtx.ActiveFiles, 1);
  RootCtx.ActiveFiles[0] := RootIdx;
  ParseFileTokens(RootIdx, RootCtx);
  RebuildCommentIndex;
  { Prototype: forward declarations are containers too (emit before gap coverage) }
  for I := 0 to High(State.Forwards) do
    if (State.Forwards[I].FileIdx >= 0) and
       (State.Forwards[I].FileIdx < Length(State.Files)) and
       (State.Forwards[I].Line >= 1) then
      AddLogicBlock(bkForwardDecl,
        State.Forwards[I].Kind + ' ' + State.Forwards[I].Name,
        -1, -1, State.Forwards[I].FileIdx, State.Forwards[I].Line,
        State.Forwards[I].FileIdx, State.Forwards[I].Line);
  { Prototype: after all blocks exist, add GAP_ containers for uncovered lines }
  for I := 0 to High(State.Files) do
    EmitCoveringGaps(I);

  RebuildContainerHierarchy;
  SaveAuditCache;
end;

BuildGlobalLineMap;
BuildLineEdgeIndex;
if Trim(Options.SearchInTarget) <> '' then
  Options.ScopeBlockIdx := ResolveBlockTargetToIndex(Options.SearchInTarget);
if LineToGSMode then
begin
  BuildGlobalStmtMap;
  EmitGLineToGS;
  Halt(0);
end;
if GlobalStmtsMode then
begin
  BuildGlobalStmtMap;
  if (Trim(GSPathArg) <> '') and (GlobalLineNum < 1) then
    GlobalLineNum := FindGSSemanticPathIndex(GSPathArg);
  Options.GlobalLineNum := GlobalLineNum;
  EmitGlobalStmts;
  Halt(0);
end;
if Options.GlobalLinesMode or Options.GlobalLineMode then
begin
  EmitGlobalLines;
  Halt(0);
end;
if Options.GetBlockMode then
begin
  EmitGetBlock(RootIdx);
  Halt(0);
end;
BeautifyRootIdx := RootIdx;

if StmtListMode then
begin
  EmitStmtListForTarget(StmtListTarget);
  Halt(0);
end;

if FragmentEditMode then
  ApplyFragmentEdit;
if Options.FixIndentMode then ApplyIndentFix;
{ Block-relative and collection-wide edits are resolved before the normal edit/apply stage }

ResolveBlockEdit;
ResolveGlobalEdit;
ResolveGlobalLineEdit;
ResolveScopedEditTarget;
if StmtEditMode then
begin
  if (Length(GStmts) = 0) and
     (IsGSPrefix(StmtEditTarget) or (Pos('.', StmtEditTarget) > 0)) then
    BuildGlobalStmtMap;
  TranslateGSLineTarget(StmtEditTarget, StmtEditIndex);
  ResolveStmtEdit(StmtEditTarget, StmtEditAction, StmtEditText, StmtEditIndex);
end;

while Length(CondStack) > 0 do
begin
  TopCond := CondStack[High(CondStack)];
  SetLength(CondStack, Length(CondStack) - 1);
  AddDiagnostic(TopCond.FileIdx, MaxIntVal(1, Length(State.Files[TopCond.FileIdx].Lines)), 1,
    EXIT_BIT_STRUCTURAL,
    'Unclosed ' + TopCond.Directive + ' opened at "' +
    FileDisplay(TopCond.FileIdx) + '": Line ' + IntToStr(TopCond.Line) +
    ', Col ' + IntToStr(TopCond.Col) + ' (missing {$ENDIF})',
    'Opened at:', TopCond.Snippet);
end;

if Options.StrictMode then
  RunStrictChecks;
if Options.EditPlanSpecified then
begin
  BM := FindScopedBlockMatch(Options.EditPlanTarget);
  if BM.Found then
  begin
    if Options.OutputRawMode then
    begin
      if (BM.BlockIdx >= 0) and (BM.BlockIdx < Length(State.LogicBlocks)) then
        for I := State.LogicBlocks[BM.BlockIdx].StartLine to State.LogicBlocks[BM.BlockIdx].EndLine do
          if (BM.MatchFileIdx >= 0) and (BM.MatchFileIdx < Length(State.Files)) and
             (I >= 1) and (I <= Length(State.Files[BM.MatchFileIdx].Lines)) then
            WriteLn(Output, State.Files[BM.MatchFileIdx].Lines[I-1]);
    end
    else
    begin
      WriteLn(Output, 'Edit plan target: file idx ', BM.MatchFileIdx, ' line ', BM.MatchLine);
      WriteLn(Output, '  GSLine: ', GSPathAtLine(BM.MatchFileIdx, BM.MatchLine));
      WriteLn(Output, '  Block idx: ', BM.BlockIdx);
      if (BM.BlockIdx >= 0) and (BM.BlockIdx < Length(State.LogicBlocks)) then
      begin
        WriteLn(Output, '  Range: lines ', State.LogicBlocks[BM.BlockIdx].StartLine,
          '..', State.LogicBlocks[BM.BlockIdx].EndLine);
        WriteLn(Output, '  Source:');
        for I := State.LogicBlocks[BM.BlockIdx].StartLine to State.LogicBlocks[BM.BlockIdx].EndLine do
          if (BM.MatchFileIdx >= 0) and (BM.MatchFileIdx < Length(State.Files)) and
             (I >= 1) and (I <= Length(State.Files[BM.MatchFileIdx].Lines)) then
            WriteLn(Output, Format('%4d | %s', [I, State.Files[BM.MatchFileIdx].Lines[I-1]]));
      end;
    end;
  end
  else
    WriteLn(ErrOutput, 'Block target not found: ', Options.EditPlanTarget);
  Halt(0);
end;

ApplyEdit(RootIdx);


  RunForwardStage;

  EmitOutputStage;
end.

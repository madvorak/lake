/-
Copyright (c) 2021 Mac Malone. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Mac Malone
-/
import Lake.Config.Load
import Lake.Config.SearchPath
import Lake.Config.InstallPath
import Lake.Config.Manifest
import Lake.Config.Resolve
import Lake.Util.Error
import Lake.Util.MainM
import Lake.Util.Cli
import Lake.CLI.Init
import Lake.CLI.Help
import Lake.CLI.Build
import Lake.CLI.Error

open System
open Lean (Json toJson fromJson?)

namespace Lake

-- # Loading Lake Config

structure LakeConfig where
  rootDir : FilePath
  configFile : FilePath
  leanInstall : LeanInstall
  lakeInstall : LakeInstall
  options : NameMap String

/-- Make a Lake `Context` from a `Workspace` and `LakeConfig`. -/
def mkLakeContext (ws : Workspace) (config : LakeConfig) : Context where
  lean := config.leanInstall
  lake := config.lakeInstall
  opaqueWs := ws

def loadPkg (config : LakeConfig) : LogIO Package := do
  setupLeanSearchPath config.leanInstall config.lakeInstall
  Package.load config.rootDir config.options config.configFile

def loadManifestMap (manifestFile : FilePath) : LogIO (Lean.NameMap PackageEntry) := do
  if let Except.ok contents ← IO.FS.readFile manifestFile  |>.toBaseIO then
    match Json.parse contents with
    | Except.ok json =>
      match fromJson? json with
      | Except.ok (manifest : Manifest) =>
        return manifest.toMap
      | Except.error e =>
        logWarning s!"improperly formatted package manifest: {e}"
        return {}
    | Except.error e =>
      logWarning s!"invalid JSON in package manifest: {e}"
      return {}
  else
    return {}

def loadWorkspace (config : LakeConfig) (updateDeps := false) : LogIO Workspace := do
  let pkg ← loadPkg config
  let ws := Workspace.ofPackage pkg
  let manifestMap ← loadManifestMap ws.manifestFile
  let (packageMap, resolvedMap) ← resolveDeps ws pkg updateDeps |>.run manifestMap
  unless resolvedMap.isEmpty do
    IO.FS.writeFile ws.manifestFile <| Json.pretty <| toJson <| Manifest.fromMap resolvedMap
  let packageMap := packageMap.insert pkg.name pkg
  return {ws with packageMap}

-- # CLI

-- ## General options for top-level `lake`

structure LakeOptions where
  rootDir : FilePath := "."
  configFile : FilePath := defaultConfigFile
  leanInstall? : Option LeanInstall := none
  lakeInstall? : Option LakeInstall := none
  configOptions : NameMap String := {}
  subArgs : List String := []
  wantsHelp : Bool := false

/-- Get the Lean installation. Error if missing. -/
def LakeOptions.getLeanInstall (opts : LakeOptions) : Except CliError LeanInstall :=
  match opts.leanInstall? with
  | none => .error CliError.unknownLeanInstall
  | some lean => .ok lean

/-- Get the Lake installation. Error if missing. -/
def LakeOptions.getLakeInstall (opts : LakeOptions) : Except CliError LakeInstall :=
  match opts.lakeInstall? with
  | none => .error CliError.unknownLakeInstall
  | some lake => .ok lake

/-- Get the Lean and Lake installation. Error if either is missing. -/
def LakeOptions.getInstall (opts : LakeOptions) : Except CliError (LeanInstall × LakeInstall) := do
  return (← opts.getLeanInstall, ← opts.getLakeInstall)

/-- Make a `LakeConfig` from a `LakeOptions`. -/
def mkLakeConfig (opts : LakeOptions) : Except CliError LakeConfig :=
  return {
    rootDir := opts.rootDir,
    configFile := opts.rootDir / opts.configFile,
    leanInstall := ← opts.getLeanInstall,
    lakeInstall := ← opts.getLakeInstall,
    options := opts.configOptions
  }

-- ## Monad

abbrev CliMainM := ExceptT CliError MainM
abbrev CliStateM := StateT LakeOptions CliMainM
abbrev CliM := ArgsT CliStateM

def CliM.run (self : CliM α) (args : List String) : BaseIO ExitCode := do
  let (leanInstall?, lakeInstall?) ← findInstall?
  let main := self args |>.run' {leanInstall?, lakeInstall?}
  let main := main.run >>= fun | .ok a => pure a | .error e => error e.toString
  main.run

-- ## Argument Parsing

def takeArg (arg : String) : CliM String := do
  match (← takeArg?) with
  | none => throw <| CliError.missingArg arg
  | some arg => pure arg

def takeOptArg (opt arg : String) : CliM String := do
  match (← takeArg?) with
  | none => throw <| CliError.missingOptArg opt arg
  | some arg => pure arg

/--
Verify that there are no CLI arguments remaining
before running the given action.
-/
def noArgsRem (act : CliStateM α) : CliM α := do
  let args ← getArgs
  if args.isEmpty then act else
    throw <| CliError.unexpectedArguments args

-- ## Option Parsing

def getWantsHelp : CliStateM Bool :=
  (·.wantsHelp) <$> get

def setLean (lean : String) : CliStateM PUnit := do
  let leanInstall? ← findLeanCmdInstall? lean
  modify ({·  with leanInstall?})

def setConfigOption (kvPair : String) : CliM PUnit :=
  let pos := kvPair.posOf '='
  let (key, val) :=
    if pos = kvPair.endPos then
      (kvPair.toName, "")
    else
      (kvPair.extract 0 pos |>.toName, kvPair.extract (kvPair.next pos) kvPair.endPos)
  modifyThe LakeOptions fun opts =>
    {opts with configOptions := opts.configOptions.insert key val}

def lakeShortOption : (opt : Char) → CliM PUnit
| 'h' => modifyThe LakeOptions ({· with wantsHelp := true})
| 'd' => do let rootDir ← takeOptArg "-d" "path"; modifyThe LakeOptions ({· with rootDir})
| 'f' => do let configFile ← takeOptArg "-f" "path"; modifyThe LakeOptions ({· with configFile})
| 'K' => do setConfigOption <| ← takeOptArg "-K" "key-value pair"
| opt => throw <| CliError.unknownShortOption opt

def lakeLongOption : (opt : String) → CliM PUnit
| "--help"  => modifyThe LakeOptions ({· with wantsHelp := true})
| "--dir"   => do let rootDir ← takeOptArg "--dir" "path"; modifyThe LakeOptions ({· with rootDir})
| "--file"  => do let configFile ← takeOptArg "--file" "path"; modifyThe LakeOptions ({· with configFile})
| "--lean"  => do setLean <| ← takeOptArg "--lean" "path or command"
| "--"      => do let subArgs ← takeArgs; modifyThe LakeOptions ({· with subArgs})
| opt       => throw <| CliError.unknownLongOption opt

def lakeOption :=
  option {
    short := lakeShortOption
    long := lakeLongOption
    longShort := shortOptionWithArg lakeShortOption
  }

-- ## Actions

/-- Verify the Lean version Lake was built with matches that of the give Lean installation. -/
def verifyLeanVersion (leanInstall : LeanInstall) : Except CliError PUnit := do
  unless leanInstall.githash == Lean.githash do
    throw <| CliError.leanRevMismatch Lean.githash leanInstall.githash

/-- Output the detected installs and verify the Lean version. -/
def verifyInstall (opts : LakeOptions) : ExceptT CliError MainM PUnit := do
  IO.println s!"Lean:\n{repr <| opts.leanInstall?}"
  IO.println s!"Lake:\n{repr <| opts.lakeInstall?}"
  let (leanInstall, _) ← opts.getInstall
  verifyLeanVersion leanInstall

/-- Exit code to return if `print-paths` cannot find the config file. -/
def noConfigFileCode : ExitCode := 2

/--
Environment variable that is set when `lake serve` cannot parse the Lake configuration file
and falls back to plain `lean --server`.
-/
def invalidConfigEnvVar := "LAKE_INVALID_CONFIG"

/--
Build a list of imports of the package
and print the `.olean` and source directories of every used package.
If no configuration file exists, exit silently with `noConfigFileCode` (i.e, 2).

The `print-paths` command is used internally by Lean 4 server.
-/
def printPaths (config : LakeConfig) (imports : List String := []) : MainM PUnit := do
  let configFile := config.rootDir / config.configFile
  if (← configFile.pathExists) then
    if (← IO.getEnv invalidConfigEnvVar) matches some .. then
      IO.eprintln s!"Error parsing '{configFile}'.  Please restart the lean server after fixing the Lake configuration file."
      exit 1
    let ws ← loadWorkspace config
    let ctx ← mkBuildContext ws config.leanInstall config.lakeInstall
    let dynlibs ← ws.root.buildImportsAndDeps imports |>.run MonadLog.eio ctx
    IO.println <| Json.compress <| toJson {ws.leanPaths with loadDynlibPaths := dynlibs}
  else
    exit noConfigFileCode

def env (cmd : String) (args : Array String := #[]) : LakeT IO UInt32 := do
  IO.Process.spawn {cmd, args, env := ← getAugmentedEnv} >>= (·.wait)

def serve (config : LakeConfig) (args : Array String) : LogIO UInt32 := do
  let (extraEnv, moreServerArgs) ←
    try
      let ws ← loadWorkspace config
      let ctx := mkLakeContext ws config
      pure (← LakeT.run ctx getAugmentedEnv, ws.root.moreServerArgs)
    catch _ =>
      let installEnv := mkInstallEnv config.leanInstall config.lakeInstall
      logWarning "package configuration has errors, falling back to plain `lean --server`"
      pure (installEnv.push (invalidConfigEnvVar, "1"), #[])
  (← IO.Process.spawn {
    cmd := config.leanInstall.lean.toString
    args := #["--server"] ++ moreServerArgs ++ args
    env := extraEnv
  }).wait

def parseScriptSpec (ws : Workspace) (spec : String) : Except CliError (Package × String) :=
  match spec.splitOn "/" with
  | [script] => return (ws.root, script)
  | [pkg, script] => return (← parsePackageSpec ws pkg, script)
  | _ => throw <| CliError.invalidScriptSpec spec

def parseTemplateSpec (spec : String) : Except CliError InitTemplate :=
  if spec.isEmpty then
    pure default
  else if let some tmp := InitTemplate.parse? spec then
    pure tmp
  else
    throw <| CliError.unknownTemplate spec

-- ## Commands

namespace lake

-- ### `lake script` CLI

namespace script

protected def list : CliM PUnit := do
  processOptions lakeOption
  let config ← mkLakeConfig (← getThe LakeOptions)
  noArgsRem do
    let ws ← loadWorkspace config
    ws.packageMap.forM fun _ pkg => do
      let pkgName := pkg.name.toString (escape := false)
      pkg.scripts.forM fun name _ =>
        let scriptName := name.toString (escape := false)
        IO.println s!"{pkgName}/{scriptName}"

protected nonrec def run : CliM PUnit := do
  processOptions lakeOption
  let spec ← takeArg "script name"; let args ← takeArgs
  let config ← mkLakeConfig (← getThe LakeOptions)
  let ws ← loadWorkspace config
  let (pkg, scriptName) ← parseScriptSpec ws spec
  if let some script := pkg.scripts.find? scriptName then
    exit <| ← script.run args |>.run {
      lean := config.leanInstall,
      lake := config.lakeInstall,
      opaqueWs := ws
    }
  else do
    throw <| CliError.unknownScript scriptName

protected def doc : CliM PUnit := do
  processOptions lakeOption
  let spec ← takeArg "script name"
  let config ← mkLakeConfig (← getThe LakeOptions)
  noArgsRem do
    let ws ← loadWorkspace config
    let (pkg, scriptName) ← parseScriptSpec ws spec
    if let some script := pkg.scripts.find? scriptName then
      match script.doc? with
      | some doc => IO.println doc
      | none => throw <| CliError.missingScriptDoc scriptName
    else
      throw <| CliError.unknownScript scriptName

protected def help : CliM PUnit := do
  IO.println <| helpScript <| (← takeArg?).getD ""

end script

def scriptCli : (cmd : String) → CliM PUnit
| "list"  => script.list
| "run"   => script.run
| "doc"   => script.doc
| "help"  => script.help
| cmd     => throw <| CliError.unknownCommand cmd

-- ### `lake` CLI

protected def new : CliM PUnit := do
  processOptions lakeOption
  let pkgName ← takeArg "package name"
  let template ← parseTemplateSpec <| (← takeArg?).getD ""
  noArgsRem <| new pkgName template

protected def init : CliM PUnit := do
  processOptions lakeOption
  let pkgName ← takeArg "package name"
  let template ← parseTemplateSpec <| (← takeArg?).getD ""
  noArgsRem <| init pkgName template

protected def script : CliM PUnit := do
  if let some cmd ← takeArg? then
    processLeadingOptions lakeOption -- between `lake script <cmd>` and args
    if (← getWantsHelp) then
      IO.println <| helpScript cmd
    else
      scriptCli cmd
  else
    throw <| CliError.missingCommand

protected def build : CliM PUnit := do
  processOptions lakeOption
  let opts ← getThe LakeOptions
  let config ← mkLakeConfig opts
  let ws ← loadWorkspace config
  let targetSpecs ← takeArgs
  let target ← show Except _ _ from do
    let targets ← targetSpecs.mapM <| parseTargetSpec ws
    if targets.isEmpty then
      resolveDefaultPackageTarget ws ws.root
    else
      return Target.collectOpaqueList targets
  let ctx ← mkBuildContext ws config.leanInstall config.lakeInstall
  BuildM.run MonadLog.io ctx target.build

protected def update : CliM PUnit := do
  processOptions lakeOption
  let config ← mkLakeConfig (← getThe LakeOptions)
  noArgsRem <| discard <| loadWorkspace config (updateDeps := true)

protected def printPaths : CliM PUnit := do
  processOptions lakeOption
  let config ← mkLakeConfig (← getThe LakeOptions)
  printPaths config (← takeArgs)

protected def clean : CliM PUnit := do
  processOptions lakeOption
  let config ← mkLakeConfig (← getThe LakeOptions)
  noArgsRem (← loadPkg config).clean

protected def serve : CliM PUnit := do
  processOptions lakeOption
  let opts ← getThe LakeOptions
  let args := opts.subArgs.toArray
  let config ← mkLakeConfig opts
  noArgsRem do exit <| ← serve config args

protected def env : CliM PUnit := do
  let cmd ← takeArg "command"; let args ← takeArgs
  let config ← mkLakeConfig (← getThe LakeOptions)
  let ws ← loadWorkspace config
  let ctx := mkLakeContext ws config
  exit <| ← (env cmd args.toArray).run ctx

protected def selfCheck : CliM PUnit := do
  processOptions lakeOption
  noArgsRem <| verifyInstall (← getThe LakeOptions)

protected def help : CliM PUnit := do
  IO.println <| help <| (← takeArg?).getD ""

end lake

def lakeCli : (cmd : String) → CliM PUnit
| "new"         => lake.new
| "init"        => lake.init
| "build"       => lake.build
| "update"      => lake.update
| "print-paths" => lake.printPaths
| "clean"       => lake.clean
| "script"      => lake.script
| "scripts"     => lake.script.list
| "run"         => lake.script.run
| "serve"       => lake.serve
| "env"         => lake.env
| "self-check"  => lake.selfCheck
| "help"        => lake.help
| cmd           => throw <| CliError.unknownCommand cmd

def lake : CliM PUnit := do
  match (← getArgs) with
  | [] => IO.println usage
  | ["--version"] => IO.println uiVersionString
  | _ => -- normal CLI
    processLeadingOptions lakeOption -- between `lake` and command
    if let some cmd ← takeArg? then
      processLeadingOptions lakeOption -- between `lake <cmd>` and args
      if (← getWantsHelp) then
        IO.println <| help cmd
      else
        lakeCli cmd
    else
      if (← getWantsHelp) then
        IO.println usage
      else
        throw <| CliError.missingCommand

def cli (args : List String) : BaseIO ExitCode :=
  (lake).run args

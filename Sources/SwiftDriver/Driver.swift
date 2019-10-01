import TSCBasic
import TSCUtility

/// How should the Swift module output be handled?
public enum ModuleOutputKind {
  /// The Swift module is a top-level output.
  case topLevel

  /// The Swift module is an auxiliary output.
  case auxiliary
}

/// The Swift driver.
public struct Driver {
  enum Error: Swift.Error {
    case invalidDriverName(String)
    case invalidInput(String)
  }

  /// Diagnostic engine for emitting warnings, errors, etc.
  public let diagnosticEngine: DiagnosticsEngine

  /// The kind of driver.
  public let driverKind: DriverKind

  /// The option table we're using.
  let optionTable: OptionTable

  /// The set of parsed options.
  var parsedOptions: ParsedOptions

  /// The working directory for the driver, if there is one.
  public let workingDirectory: AbsolutePath?

  /// The set of input files
  public let inputFiles: [InputFile]

  /// The mapping from input files to output files for each kind.
  internal var outputFileMap: OutputFileMap

  /// The mode in which the compiler will execute.
  public let compilerMode: CompilerMode

  /// The type of the primary output generated by the compiler.
  public let compilerOutputType: FileType?

  /// The type of the primary output generated by the linker.
  public let linkerOutputType: LinkOutputType?

  /// The level of debug information to produce.
  public let debugInfoLevel: DebugInfoLevel?

  /// The debug info format to use.
  public let debugInfoFormat: DebugInfoFormat

  /// The form that the module output will take, e.g., top-level vs. auxiliary,
  /// or \c nil to indicate that there is no module to output.
  public let moduleOutputKind: ModuleOutputKind?

  /// The name of the Swift module being built.
  public let moduleName: String

  /// Handler for emitting diagnostics to stderr.
  public static let stderrDiagnosticsHandler: DiagnosticsEngine.DiagnosticsHandler = { diagnostic in
    let stream = stderrStream
    if !(diagnostic.location is UnknownLocation) {
        stream <<< diagnostic.location.description <<< ": "
    }

    switch diagnostic.message.behavior {
    case .error:
      stream <<< "error: "
    case .warning:
      stream <<< "warning: "
    case .note:
      stream <<< "note: "
    case .ignored:
        break
    }

    stream <<< diagnostic.localizedDescription <<< "\n"
    stream.flush()
  }

  /// Create the driver with the given arguments.
  public init(args: [String], diagnosticsHandler: @escaping DiagnosticsEngine.DiagnosticsHandler = Driver.stderrDiagnosticsHandler) throws {
    // FIXME: Determine if we should run as subcommand.

    self.diagnosticEngine = DiagnosticsEngine(handlers: [diagnosticsHandler])
    self.driverKind = try Self.determineDriverKind(args: args)
    self.optionTable = OptionTable()
    self.parsedOptions = try optionTable.parse(Array(args.dropFirst()))

    // Compute the working directory.
    workingDirectory = try parsedOptions.getLastArgument(.working_directory).map { workingDirectoryArg in
      let cwd = localFileSystem.currentWorkingDirectory
      return try cwd.map{ AbsolutePath(workingDirectoryArg.asSingle, relativeTo: $0) } ?? AbsolutePath(validating: workingDirectoryArg.asSingle)
    }

    // Apply the working directory to the parsed options.
    if let workingDirectory = self.workingDirectory {
      try Self.applyWorkingDirectory(workingDirectory, to: &self.parsedOptions)
    }

    // Classify and collect all of the input files.
    self.inputFiles = try Self.collectInputFiles(&self.parsedOptions)

    // Initialize an empty output file map, which will be populated when we start creating jobs.
    //
    // FIXME: If one of the -output-file-map options was given, parse that file into outputFileMap.
    self.outputFileMap = OutputFileMap()

    // Determine the compilation mode.
    self.compilerMode = Self.computeCompilerMode(&parsedOptions, driverKind: driverKind)

    // Figure out the primary outputs from the driver.
    (self.compilerOutputType, self.linkerOutputType) = Self.determinePrimaryOutputs(&parsedOptions, driverKind: driverKind, diagnosticsEngine: diagnosticEngine)

    // Compute debug information output.
    (self.debugInfoLevel, self.debugInfoFormat) = Self.computeDebugInfo(&parsedOptions, diagnosticsEngine: diagnosticEngine)

    // Determine the module we're building and whether/how the module file itself will be emitted.
    (self.moduleOutputKind, self.moduleName) = Self.computeModuleInfo(
      &parsedOptions, compilerOutputType: compilerOutputType, compilerMode: compilerMode, linkerOutputType: linkerOutputType,
      debugInfoLevel: debugInfoLevel, diagnosticsEngine: diagnosticEngine)
  }

  /// Determine the driver kind based on the command-line arguments.
  public static func determineDriverKind(
    args: [String],
    cwd: AbsolutePath? = localFileSystem.currentWorkingDirectory
  ) throws -> DriverKind {
    // Get the basename of the driver executable.
    let execPath = try cwd.map{ AbsolutePath(args[0], relativeTo: $0) } ?? AbsolutePath(validating: args[0])
    var driverName = execPath.basename

    // Determine driver kind based on the first argument.
    if args.count > 1 {
      let driverModeOption = "--driver-mode="
      if args[1].starts(with: driverModeOption) {
        driverName = String(args[1].dropFirst(driverModeOption.count))
      } else if args[1] == "-frontend" {
        return .frontend
      } else if args[1] == "-modulewrap" {
        return .moduleWrap
      }
    }

    switch driverName {
    case "swift":
      return .interactive
    case "swiftc":
      return .batch
    case "swift-autolink-extract":
      return .autolinkExtract
    case "swift-indent":
      return .indent
    default:
      throw Error.invalidDriverName(driverName)
    }
  }

  /// Run the driver.
  public mutating func run() throws {
    // We just need to invoke the corresponding tool if the kind isn't Swift compiler.
    guard driverKind.isSwiftCompiler else {
      let swiftCompiler = try getSwiftCompilerPath()
      return try exec(path: swiftCompiler.pathString, args: ["swift"] + parsedOptions.commandLine)
    }

    if parsedOptions.contains(.help) || parsedOptions.contains(.help_hidden) {
      optionTable.printHelp(usage: driverKind.usage, title: driverKind.title, includeHidden: parsedOptions.contains(.help_hidden))
      return
    }

    switch compilerMode {
    case .standardCompile:
      break
    case .singleCompile:
      break
    case .repl:
      break
    case .immediate:
      break
    }
  }

  /// Returns the path to the Swift binary.
  func getSwiftCompilerPath() throws -> AbsolutePath {
    // FIXME: This is very preliminary. Need to figure out how to get the actual Swift executable path.
    let path = try Process.checkNonZeroExit(
      arguments: ["xcrun", "-sdk", "macosx", "--find", "swift"]).spm_chomp()
    return AbsolutePath(path)
  }
}

extension Driver {
  /// Compute the compiler mode based on the options.
  private static func computeCompilerMode(
    _ parsedOptions: inout ParsedOptions,
    driverKind: DriverKind
  ) -> CompilerMode {
    // Some output flags affect the compiler mode.
    if let outputOption = parsedOptions.getLast(in: .modes) {
      switch outputOption.option! {
      case .emit_pch, .emit_imported_modules, .index_file:
        return .singleCompile

      case .repl, .deprecated_integrated_repl, .lldb_repl:
        return .repl

      default:
        // Output flag doesn't determine the compiler mode.
        break
      }
    }

    if driverKind == .interactive {
      return parsedOptions.hasAnyInput ? .immediate : .repl
    }

    let requiresSingleCompile = parsedOptions.contains(.whole_module_optimization)

    // FIXME: Handle -enable-batch-mode and -disable-batch-mode flags.

    if requiresSingleCompile {
      return .singleCompile
    }

    return .standardCompile
  }
}

/// Input and output file handling.
extension Driver {
  /// Translate the given input file into a virtual path.
  ///
  /// FIXME: Left on Driver in case we want to lazily translate things.
  func translateInputFile(_ file: File) -> VirtualPath {
    assert(file != .standardOutput, "Standard output cannot be an input file")
    return .path(file)
  }

  /// Apply the given working directory to all paths in the parsed options.
  private static func applyWorkingDirectory(_ workingDirectory: AbsolutePath,
                                            to parsedOptions: inout ParsedOptions) throws {
    parsedOptions.forEachModifying { parsedOption in
      // Only translate input arguments and options whose arguments are paths.
      if let option = parsedOption.option {
        if !option.attributes.contains(.argumentIsPath) { return }
      } else if !parsedOption.isInput {
        return
      }

      let translatedArgument: ParsedOption.Argument
      switch parsedOption.argument {
      case .none:
        return

      case .single(let arg):
        if arg == "-" {
          translatedArgument = parsedOption.argument
        } else {
          translatedArgument = .single(AbsolutePath(arg, relativeTo: workingDirectory).pathString)
        }

      case .multiple(let args):
        translatedArgument = .multiple(args.map { arg in
          AbsolutePath(arg, relativeTo: workingDirectory).pathString
        })
      }

      parsedOption = .init(option: parsedOption.option, argument: translatedArgument)
    }
  }

  /// Collect all of the input files from the parsed options, translating them into input files.
  private static func collectInputFiles(_ parsedOptions: inout ParsedOptions) throws -> [InputFile] {
    return try parsedOptions.allInputs.map { input in
      // Standard input is assumed to be Swift code.
      if input == "-" {
        return InputFile(file: .standardInput, type: .swift)
      }

      // Resolve the input file.
      let file: File
      let fileExtension: String
      if let absolute = try? AbsolutePath(validating: input) {
        file = .absolute(absolute)
        fileExtension = absolute.extension ?? ""
      } else {
        let relative = try RelativePath(validating: input)
        fileExtension = relative.extension ?? ""
        file = .relative(relative)
      }

      // Determine the type of the input file based on its extension.
      // If we don't recognize the extension, treat it as an object file.
      // FIXME: The object-file default is carried over from the existing
      // driver, but seems odd.
      let fileType = FileType(rawValue: fileExtension) ?? FileType.object

      return InputFile(file: file, type: fileType)
    }
  }

  /// Determine the primary compiler and linker output kinds.
  private static func determinePrimaryOutputs(
    _ parsedOptions: inout ParsedOptions,
    driverKind: DriverKind,
    diagnosticsEngine: DiagnosticsEngine
  ) -> (FileType?, LinkOutputType?) {
    // By default, the driver does not link its output. However, this will be updated below.
    var compilerOutputType: FileType? = (driverKind == .interactive ? nil : .object)
    var linkerOutputType: LinkOutputType? = nil

    if let outputOption = parsedOptions.getLast(in: .modes) {
      switch outputOption.option! {
      case .emit_executable:
        if parsedOptions.contains(.static) {
          diagnosticsEngine.emit(.error_static_emit_executable_disallowed)
        }
        linkerOutputType = .executable
        compilerOutputType = .object

      case .emit_library:
        linkerOutputType = parsedOptions.hasArgument(.static) ? .staticLibrary : .dynamicLibrary
        compilerOutputType = .object

      case .emit_object:
        compilerOutputType = .object

      case .emit_assembly:
        compilerOutputType = .assembly

      case .emit_sil:
        compilerOutputType = .sil

      case .emit_silgen:
        compilerOutputType = .raw_sil

      case .emit_sib:
        compilerOutputType = .sib

      case .emit_sibgen:
        compilerOutputType = .raw_sib

      case .emit_ir:
        compilerOutputType = .llvmIR

      case .emit_bc:
        compilerOutputType = .llvmBitcode

      case .dump_ast:
        compilerOutputType = .ast

      case .emit_pch:
        compilerOutputType = .pch

      case .emit_imported_modules:
        compilerOutputType = .importedModules

      case .index_file:
        compilerOutputType = .indexData

      case .update_code:
        compilerOutputType = .remap
        linkerOutputType = nil

      case .parse, .resolve_imports, .typecheck, .dump_parse, .emit_syntax,
           .print_ast, .dump_type_refinement_contexts, .dump_scope_maps,
           .dump_interface_hash, .dump_type_info, .verify_debug_info:
        compilerOutputType = nil

      case .i:
        // FIXME: diagnose this
        break

      case .repl, .deprecated_integrated_repl, .lldb_repl:
        compilerOutputType = nil

      default:
        fatalError("unhandled output mode option")
      }
    } else if (parsedOptions.hasArgument(.emit_module, .emit_module_path)) {
      compilerOutputType = .swiftModule
    } else if (driverKind != .interactive) {
      linkerOutputType = .executable
    }

    return (compilerOutputType, linkerOutputType)
  }
}

// Debug information
extension Driver {
  /// Compute the level of debug information we are supposed to produce.
  private static func computeDebugInfo(_ parsedOptions: inout ParsedOptions, diagnosticsEngine: DiagnosticsEngine) -> (DebugInfoLevel?, DebugInfoFormat) {
    // Determine the debug level.
    let level: DebugInfoLevel?
    if let levelOption = parsedOptions.getLast(in: .g) {
      switch levelOption.option! {
      case .g:
        level = .astTypes

      case .gline_tables_only:
        level = .lineTables

      case .gdwarf_types:
        level = .dwarfTypes

      case .gnone:
        level = nil

      default:
        fatalError("Unhandle option in the '-g' group")
      }
    } else {
      level = nil
    }

    // Determine the debug info format.
    let format: DebugInfoFormat
    if let formatArg = parsedOptions.getLastArgument(.debug_info_format) {
      if let parsedFormat = DebugInfoFormat(rawValue: formatArg.asSingle) {
        format = parsedFormat
      } else {
        diagnosticsEngine.emit(.error_invalid_arg_value(arg: .debug_info_format, value: formatArg.asSingle))
        format = .dwarf
      }

      if !parsedOptions.contains(in: .g) {
        diagnosticsEngine.emit(.error_option_missing_required_argument(option: .debug_info_format, requiredArg: .g))
      }
    } else {
      // Default to DWARF.
      format = .dwarf
    }

    if format == .codeView && (level == .lineTables || level == .dwarfTypes) {
      let levelOption = parsedOptions.getLast(in: .g)!.option!
      diagnosticsEngine.emit(.error_argument_not_allowed_with(arg: format.rawValue, other: levelOption.spelling))
    }

    return (level, format)
  }
}

// Module computation.
extension Driver {
  /// Compute the base name of the given path without an extension.
  private static func baseNameWithoutExtension(_ path: String) -> String {
    var hasExtension = false
    return baseNameWithoutExtension(path, hasExtension: &hasExtension)
  }

  /// Compute the base name of the given path without an extension.
  private static func baseNameWithoutExtension(_ path: String, hasExtension: inout Bool) -> String {
    if let absolute = try? AbsolutePath(validating: path) {
      hasExtension = absolute.extension != nil
      return absolute.basenameWithoutExt
    }

    if let relative = try? RelativePath(validating: path) {
      hasExtension = relative.extension != nil
      return relative.basenameWithoutExt
    }

    hasExtension = false
    return ""
  }

  /// Whether we are going to be building an executable.
  ///
  /// FIXME: Why "maybe"? Why isn't this all known in advance as captured in
  /// linkerOutputType?
  private static func maybeBuildingExecutable(
    _ parsedOptions: inout ParsedOptions,
    linkerOutputType: LinkOutputType?
  ) -> Bool {
    switch linkerOutputType {
    case .executable:
      return true

    case .dynamicLibrary, .staticLibrary:
      return false

    default:
      break
    }

    if parsedOptions.hasArgument(.parse_as_library, .parse_stdlib) {
      return false
    }

    return parsedOptions.allInputs.count == 1
  }

  /// Determine how the module will be emitted and the name of the module.
  private static func computeModuleInfo(
    _ parsedOptions: inout ParsedOptions,
    compilerOutputType: FileType?,
    compilerMode: CompilerMode,
    linkerOutputType: LinkOutputType?,
    debugInfoLevel: DebugInfoLevel?,
    diagnosticsEngine: DiagnosticsEngine
  ) -> (ModuleOutputKind?, String) {
    var moduleOutputKind: ModuleOutputKind?
    if parsedOptions.hasArgument(.emit_module, .emit_module_path) {
      // The user has requested a module, so generate one and treat it as
      // top-level output.
      moduleOutputKind = .topLevel
    } else if (debugInfoLevel?.requiresModule ?? false) && linkerOutputType != nil {
      // An option has been passed which requires a module, but the user hasn't
      // requested one. Generate a module, but treat it as an intermediate output.
      moduleOutputKind = .auxiliary
    } else if (compilerMode != .singleCompile &&
               parsedOptions.hasArgument(.emit_objc_header, .emit_objc_header_path,
                                         .emit_module_interface, .emit_module_interface_path)) {
      // An option has been passed which requires whole-module knowledge, but we
      // don't have that. Generate a module, but treat it as an intermediate
      // output.
      moduleOutputKind = .auxiliary
    } else {
      // No options require a module, so don't generate one.
      moduleOutputKind = nil
    }

    // The REPL and immediate mode do not support module output
    if moduleOutputKind != nil && (compilerMode == .repl || compilerMode == .immediate) {
      diagnosticsEngine.emit(.error_mode_cannot_emit_module)
      moduleOutputKind = nil
    }

    var moduleName: String
    if let arg = parsedOptions.getLastArgument(.module_name) {
      moduleName = arg.asSingle
    } else if compilerMode == .repl {
      // REPL mode should always use the REPL module.
      moduleName = "REPL"
    } else if let outputArg = parsedOptions.getLastArgument(.o) {
      var hasExtension = false
      var rawModuleName = baseNameWithoutExtension(outputArg.asSingle, hasExtension: &hasExtension)
      if (linkerOutputType == .dynamicLibrary || linkerOutputType == .staticLibrary) &&
        hasExtension && rawModuleName.starts(with: "lib") {
        // Chop off a "lib" prefix if we're building a library.
        rawModuleName = String(rawModuleName.dropFirst(3))
      }

      moduleName = rawModuleName
    } else if parsedOptions.allInputs.count == 1 {
      moduleName = baseNameWithoutExtension(parsedOptions.allInputs.first!)
    } else if compilerOutputType == nil || maybeBuildingExecutable(&parsedOptions, linkerOutputType: linkerOutputType) {
      // FIXME: Current driver notes that this is a "fallback module name"
      moduleName = "main"
    } else {
      // FIXME: Current driver notes that this is a "fallback module name".
      moduleName = ""
    }

    if !moduleName.isSwiftIdentifier {
      diagnosticsEngine.emit(.error_bad_module_name(moduleName: moduleName, explicitModuleName: parsedOptions.contains(.module_name)))
      moduleName = "__bad__"
    } else if moduleName == "Swift" && !parsedOptions.contains(.parse_stdlib) {
      diagnosticsEngine.emit(.error_stdlib_module_name(moduleName: moduleName, explicitModuleName: parsedOptions.contains(.module_name)))
      moduleName = "__bad__"
    }

    return (moduleOutputKind, moduleName)
  }
}

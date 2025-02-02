//===--------------- BuildRecordInfo.swift --------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import TSCBasic
import SwiftOptions

struct JobResult {
  let j: Job
  let result: ProcessResult
  init(_ j: Job, _ result: ProcessResult) {
    self.j = j
    self.result = result
  }
}

/// Holds information required to read and write the build record (aka compilation record)
/// This info is always written, but only read for incremental compilation.
 class BuildRecordInfo {
  let buildRecordPath: VirtualPath
  let fileSystem: FileSystem
  let currentArgsHash: String
  let actualSwiftVersion: String
  let timeBeforeFirstJob: Date
  let diagnosticEngine: DiagnosticsEngine
  let compilationInputModificationDates: [TypedVirtualPath: Date]

  var finishedJobResults  = [JobResult]()

  init?(
    actualSwiftVersion: String,
    compilerOutputType: FileType?,
    workingDirectory: AbsolutePath?,
    diagnosticEngine: DiagnosticsEngine,
    fileSystem: FileSystem,
    moduleOutputInfo: ModuleOutputInfo,
    outputFileMap: OutputFileMap?,
    parsedOptions: ParsedOptions,
    recordedInputModificationDates: [TypedVirtualPath: Date]
  ) {
    // Cannot write a buildRecord without a path.
    guard let buildRecordPath = Self.computeBuildRecordPath(
            outputFileMap: outputFileMap,
            compilerOutputType: compilerOutputType,
            workingDirectory: workingDirectory,
            diagnosticEngine: diagnosticEngine)
    else {
      return nil
    }
    self.actualSwiftVersion = actualSwiftVersion
    self.currentArgsHash = Self.computeArgsHash(parsedOptions)
    self.buildRecordPath = buildRecordPath
    self.compilationInputModificationDates =
      recordedInputModificationDates.filter { input, _ in
        input.type.isPartOfSwiftCompilation
      }
    self.diagnosticEngine = diagnosticEngine
    self.fileSystem = fileSystem
    self.timeBeforeFirstJob = Date()
   }

  private static func computeArgsHash(_ parsedOptionsArg: ParsedOptions
  ) -> String {
    var parsedOptions = parsedOptionsArg
    let hashInput = parsedOptions
      .filter { $0.option.affectsIncrementalBuild && $0.option.kind != .input}
      .map { $0.option.spelling }
      .sorted()
      .joined()
    #if os(macOS)
    if #available(macOS 10.15, iOS 13, *) {
      return CryptoKitSHA256().hash(hashInput).hexadecimalRepresentation
    } else {
      return SHA256().hash(hashInput).hexadecimalRepresentation
    }
    #else
    return SHA256().hash(hashInput).hexadecimalRepresentation
    #endif
  }

  /// Determine the input and output path for the build record
  private static func computeBuildRecordPath(
    outputFileMap: OutputFileMap?,
    compilerOutputType: FileType?,
    workingDirectory: AbsolutePath?,
    diagnosticEngine: DiagnosticsEngine
  ) -> VirtualPath? {
    // FIXME: This should work without an output file map. We should have
    // another way to specify a build record and where to put intermediates.
    guard let ofm = outputFileMap else {
      return nil
    }
    guard let partialBuildRecordPath =
            ofm.existingOutputForSingleInput(outputType: .swiftDeps)
    else {
      diagnosticEngine.emit(.warning_incremental_requires_build_record_entry)
      return nil
    }
    return workingDirectory
      .map(partialBuildRecordPath.resolvedRelativePath(base:))
      ?? partialBuildRecordPath
  }

  /// Write out the build record.
  /// `Jobs` must include all of the compilation jobs.
  /// `Inputs` will hold all the primary inputs that were not compiled because of incremental compilation
  func writeBuildRecord(_ jobs: [Job], _ skippedInputs: Set<TypedVirtualPath>? ) {
    guard let absPath = buildRecordPath.absolutePath else {
      diagnosticEngine.emit(
        .warning_could_not_write_build_record_not_absolutePath(buildRecordPath))
      return
    }
    preservePreviousBuildRecord(absPath)

    let buildRecord = BuildRecord(
      jobs: jobs,
      finishedJobResults: finishedJobResults,
      skippedInputs: skippedInputs,
      compilationInputModificationDates: compilationInputModificationDates,
      actualSwiftVersion: actualSwiftVersion,
      argsHash: currentArgsHash,
      timeBeforeFirstJob: timeBeforeFirstJob)

    guard let contents = buildRecord.encode(currentArgsHash: currentArgsHash,
                                            diagnosticEngine: diagnosticEngine)
    else {
      return
    }
    do {
      try fileSystem.writeFileContents(absPath,
                                       bytes: ByteString(encodingAsUTF8: contents))
    }
    catch {
      diagnosticEngine.emit(.warning_could_not_write_build_record(absPath))
    }
 }

  /// Before writing to the dependencies file path, preserve any previous file
  /// that may have been there. No error handling -- this is just a nicety, it
  /// doesn't matter if it fails.
  /// Added for the sake of compatibility with the legacy driver.
  private func preservePreviousBuildRecord(_ oldPath: AbsolutePath) {
    let newPath = oldPath.withTilde()
    try? fileSystem.move(from: oldPath, to: newPath)
  }


// TODO: Incremental too many names, buildRecord BuildRecord outofdatemap
  func populateOutOfDateBuildRecord(
    inputFiles: [TypedVirtualPath],
    reportIncrementalDecision: (String) -> Void,
    reportDisablingIncrementalBuild: (String) -> Void,
    reportIncrementalCompilationHasBeenDisabled: (String) -> Void
  ) -> BuildRecord? {
    let contents: String
    do {
      contents = try fileSystem.readFileContents(buildRecordPath).cString
     }
    catch {
      reportIncrementalDecision("Incremental compilation could not read build record at \(buildRecordPath)")
      reportDisablingIncrementalBuild("could not read build record")
      return nil
    }
    func failedToReadOutOfDateMap(_ reason: String? = nil) {
      let why = "malformed build record file\(reason.map {" " + $0} ?? "")"
      reportIncrementalDecision(
        "Incremental compilation has been disabled due to \(why) '\(buildRecordPath)'")
        reportDisablingIncrementalBuild(why)
    }
    guard let outOfDateBuildRecord = BuildRecord(contents: contents,
                                                 failedToReadOutOfDateMap: failedToReadOutOfDateMap)
    else {
      return nil
    }
    guard actualSwiftVersion == outOfDateBuildRecord.swiftVersion
    else {
      let why = "compiler version mismatch. Compiling with: \(actualSwiftVersion). Previously compiled with: \(outOfDateBuildRecord.swiftVersion)"
      // mimic legacy
      reportIncrementalCompilationHasBeenDisabled("due to a " + why)
      reportDisablingIncrementalBuild(why)
      return nil
    }
    guard outOfDateBuildRecord.argsHash.map({$0 == currentArgsHash}) ?? true else {
      let why = "different arguments were passed to the compiler"
      // mimic legacy
      reportIncrementalCompilationHasBeenDisabled(" because " + why)
      reportDisablingIncrementalBuild(why)
      return nil
    }
    return outOfDateBuildRecord
  }

  func jobFinished(job: Job, result: ProcessResult) {
    finishedJobResults.append(JobResult(job, result))
  }
}

fileprivate extension AbsolutePath {
  func withTilde() -> Self {
    parentDirectory.appending(component: basename + "~")
  }
}

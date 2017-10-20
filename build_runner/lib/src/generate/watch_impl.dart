// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';

import 'package:build/build.dart';
import 'package:build_runner/src/watcher/asset_change.dart';
import 'package:build_runner/src/watcher/graph_watcher.dart';
import 'package:build_runner/src/watcher/node_watcher.dart';
import 'package:logging/logging.dart';
import 'package:watcher/watcher.dart';
import 'package:stream_transform/stream_transform.dart';

import '../asset_graph/graph.dart';
import '../asset_graph/node.dart';
import '../changes/build_script_updates.dart';
import '../package_graph/package_graph.dart';
import '../util/constants.dart';
import 'build_definition.dart';
import 'build_impl.dart';
import 'build_result.dart';
import 'directory_watcher_factory.dart';
import 'options.dart';
import 'phase.dart';

final _logger = new Logger('Watch');

/// Repeatedly run builds as files change on disk until [until] fires.
///
/// Sets up file watchers and collects changes then triggers new builds. When
/// [until] fires the file watchers will be stopped and up to one additional
/// build may run if there were pending changes.
///
/// The [BuildState.buildResults] stream will end after the final build has been
/// run.
WatchImpl runWatch(
        BuildOptions options, List<BuildAction> buildActions, Future until) =>
    new WatchImpl(options, buildActions, until);

typedef Future<BuildResult> _BuildAction(List<List<AssetChange>> changes);

class WatchImpl implements BuildState {
  AssetGraph _assetGraph;

  final String _buildDir;

  /// Delay to wait for more file watcher events.
  final Duration _debounceDelay;

  /// Injectable factory for creating directory watchers.
  final DirectoryWatcherFactory _directoryWatcherFactory;

  /// The [PackageGraph] for the current program.
  final PackageGraph packageGraph;

  @override
  Future<BuildResult> currentBuild;

  /// Pending expected delete events from the build.
  final Set<AssetId> _expectedDeletes = new Set<AssetId>();

  final _readerCompleter = new Completer<AssetReader>();
  Future<AssetReader> get reader => _readerCompleter.future;

  WatchImpl(BuildOptions options, List<BuildAction> buildActions, Future until)
      : _buildDir = options.buildDir,
        _directoryWatcherFactory = options.directoryWatcherFactory,
        _debounceDelay = options.debounceDelay,
        packageGraph = options.packageGraph {
    buildResults = _run(options, buildActions, until).asBroadcastStream();
  }

  @override
  Stream<BuildResult> buildResults;

  /// Runs a build any time relevant files change.
  ///
  /// Only one build will run at a time, and changes are batched.
  ///
  /// File watchers are scheduled synchronously.
  Stream<BuildResult> _run(
      BuildOptions options, List<BuildAction> buildActions, Future until) {
    var fatalBuildCompleter = new Completer();
    var firstBuildCompleter = new Completer<BuildResult>();
    currentBuild = firstBuildCompleter.future;
    var controller = new StreamController<BuildResult>();

    // We need this inside `doBuild`, but we won't actually create it until
    // the end of this function. It must be non-null before `doBuild` is
    // invoked.
    BuildImpl build;

    Future<BuildResult> doBuild(List<List<AssetChange>> changes) async {
      assert(build != null);

      _expectedDeletes.clear();
      if (await new BuildScriptUpdates(options)
          .isNewerThan(_assetGraph.validAsOf)) {
        fatalBuildCompleter.complete();
        _logger.severe('Terminating builds due to build script update');
        return new BuildResult(BuildStatus.failure, []);
      }
      return build.run(_collectChanges(changes));
    }

    var terminate = Future.any([until, fatalBuildCompleter.future]).then((_) {
      _logger.info('Terminating. No further builds will be scheduled');
    });

    // Start watching files immediately, before the first build is even started.
    new PackageGraphWatcher(packageGraph,
            logger: _logger,
            watch: (node) => new PackageNodeWatcher(node, watch: (path) {
                  return _directoryWatcherFactory(path);
                }))
        .watch()
        .asyncMap<AssetChange>((change) {
          // Delay any events until the first build is completed.
          if (firstBuildCompleter.isCompleted) return change;
          return firstBuildCompleter.future.then((_) => change);
        })
        .where(_shouldProcess)
        .transform(debounceBuffer(_debounceDelay))
        .transform(takeUntil(terminate))
        .transform(asyncMapBuffer(_recordCurrentBuild(doBuild)))
        .listen(controller.add)
        .onDone(() {
          _logger.info('Builds finished. Safe to exit');
          controller.close();
        });

    // Schedule the actual first build for the future so we can return the
    // stream synchronously.
    () async {
      var buildDefinition = await BuildDefinition.load(options, buildActions);
      _readerCompleter.complete(buildDefinition.reader);
      _assetGraph = buildDefinition.assetGraph;
      build = await BuildImpl.create(buildDefinition, buildActions,
          onDelete: _expectedDeletes.add);

      controller.add(build.firstBuild);
      firstBuildCompleter.complete(build.firstBuild);
    }();

    return controller.stream;
  }

  _BuildAction _recordCurrentBuild(_BuildAction build) => (changes) =>
      currentBuild = build(changes)..then((_) => currentBuild = null);

  /// Checks if we should skip a watch event for this [change].
  bool _shouldProcess(AssetChange change) {
    assert(_assetGraph != null);
    if (_isBuildDirFile(change)) return false;
    if (_isCacheFile(change)) return false;
    if (_isGitFile(change)) return false;
    if (_hasNoOutputs(change)) return false;
    if (_isEditOnGeneratedFile(change)) return false;
    if (_isExpectedDelete(change)) return false;
    if (_isUnwatchedDelete(change)) return false;
    return true;
  }

  bool _isBuildDirFile(AssetChange change) =>
      change.id.package == packageGraph.root.name &&
      change.id.path.startsWith(_buildDir);

  bool _isCacheFile(AssetChange change) => change.id.path.startsWith(cacheDir);

  bool _isGitFile(AssetChange change) => change.id.path.startsWith('.git/');

  bool _hasNoOutputs(AssetChange change) =>
      _assetGraph.contains(change.id) &&
      _assetGraph.get(change.id).outputs.isEmpty;

  bool _isEditOnGeneratedFile(AssetChange change) =>
      _assetGraph.get(change.id) is GeneratedAssetNode &&
      change.type != ChangeType.REMOVE;

  bool _isExpectedDelete(AssetChange change) =>
      _expectedDeletes.remove(change.id);

  bool _isUnwatchedDelete(AssetChange change) =>
      change.type == ChangeType.REMOVE && !_assetGraph.contains(change.id);
}

Map<AssetId, ChangeType> _collectChanges(List<List<AssetChange>> changes) {
  var changeMap = <AssetId, ChangeType>{};
  for (var change in changes.expand((l) => l)) {
    var originalChangeType = changeMap[change.id];
    if (originalChangeType != null) {
      switch (originalChangeType) {
        case ChangeType.ADD:
          if (change.type == ChangeType.REMOVE) {
            // ADD followed by REMOVE, just remove the change.
            changeMap.remove(change.id);
          }
          break;
        case ChangeType.REMOVE:
          if (change.type == ChangeType.ADD) {
            // REMOVE followed by ADD, convert to a MODIFY
            changeMap[change.id] = ChangeType.MODIFY;
          } else if (change.type == ChangeType.MODIFY) {
            // REMOVE followed by MODIFY isn't sensible, just throw.
            throw new StateError(
                'Internal error, got REMOVE event followed by MODIFY event for '
                '${change.id}.');
          }
          break;
        case ChangeType.MODIFY:
          if (change.type == ChangeType.REMOVE) {
            // MODIFY followed by REMOVE, convert to REMOVE
            changeMap[change.id] = change.type;
          } else if (change.type == ChangeType.ADD) {
            // MODIFY followed by ADD isn't sensible, just throw.
            throw new StateError(
                'Internal error, got MODIFY event followed by ADD event for '
                '${change.id}.');
          }
          break;
      }
    } else {
      changeMap[change.id] = change.type;
    }
  }
  return changeMap;
}

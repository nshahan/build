// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:test/test.dart';

void main() {
  group('should resolveSource of', () {
    test('a simple dart file', () async {
      var libExample = await resolveSource(r'''
        library example;

        class Foo {}
      ''', (resolver) => resolver.findLibraryByName('example'));
      expect(libExample.getType('Foo'), isNotNull);
    });

    test('a simple dart file with dart: dependencies', () async {
      var libExample = await resolveSource(r'''
        library example;

        import 'dart:collection';

        abstract class Foo implements LinkedHashMap {}
      ''', (resolver) => resolver.findLibraryByName('example'));
      var classFoo = libExample.getType('Foo');
      expect(
        classFoo.allSupertypes.map(_toStringId),
        contains('dart:collection#LinkedHashMap'),
      );
    });

    test('a simple dart file package: dependencies', () async {
      var libExample = await resolveSource(r'''
        library example;

        import 'package:collection/collection.dart';

        abstract class Foo implements Equality {}
      ''', (resolver) => resolver.findLibraryByName('example'));
      var classFoo = libExample.getType('Foo');
      expect(
        classFoo.allSupertypes.map(_toStringId),
        contains('asset:collection#Equality'),
      );
    });

    test('waits for tearDown', () async {
      var resolverDone = new Completer<Null>();
      var resolver = await resolveSource(r'''
        library example;

        import 'package:collection/collection.dart';

        abstract class Foo implements Equality {}
      ''', (resolver) => resolver, tearDown: resolverDone.future);
      expect(
          await resolver.libraries.any((library) => library.name == 'example'),
          true);
      var libExample = await resolver.findLibraryByName('example');
      resolverDone.complete();
      var classFoo = libExample.getType('Foo');
      expect(
        classFoo.allSupertypes.map(_toStringId),
        contains('asset:collection#Equality'),
      );
    });

    test('can do expects inside the action', () async {
      await resolveSource(r'''
        library example;

        import 'package:collection/collection.dart';

        abstract class Foo implements Equality {}
      ''', (resolver) async {
        var libExample = await resolver.findLibraryByName('example');
        var classFoo = libExample.getType('Foo');
        expect(classFoo.allSupertypes.map(_toStringId),
            contains('asset:collection#Equality'));
      });
    });
  });

  group('should resolveAsset', () {
    test('asset:build_test/test/_files/example_lib.dart', () async {
      var asset = new AssetId('build_test', 'test/_files/example_lib.dart');
      var libExample = await resolveAsset(
          asset, (resolver) => resolver.findLibraryByName('example_lib'));
      expect(libExample.getType('Example'), isNotNull);
    });
  });
}

String _toStringId(InterfaceType t) =>
    '${t.element.source.uri.toString().split('/').first}#${t.name}';

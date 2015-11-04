// Copyright 2015 The Vanadium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library syncbase_database_test;

import 'dart:async';
import 'dart:convert' show UTF8;

import 'package:test/test.dart';

import 'package:syncbase/src/testing_instrumentation.dart' as testing;
import 'package:syncbase/syncbase_client.dart'
    show SyncbaseClient, WatchChangeTypes, WatchChange, WatchGlobStreamImpl;

import './utils.dart' as utils;

runDatabaseTests(SyncbaseClient c) {
  test('getting a handle to a database', () {
    var app = c.app(utils.uniqueName('app'));
    var dbName = utils.uniqueName('db');
    var db = app.noSqlDatabase(dbName);
    expect(db.name, equals(dbName));
    expect(db.fullName, equals(app.fullName + '/' + dbName));
  });

  test('creating and destroying a database', () async {
    var app = c.app(utils.uniqueName('app'));
    await app.create(utils.emptyPerms());

    var db = app.noSqlDatabase(utils.uniqueName('db'));

    expect(await db.exists(), equals(false));
    await db.create(utils.emptyPerms());
    expect(await db.exists(), equals(true));
    await db.destroy();
    expect(await db.exists(), equals(false));
  });

  test('listing tables', () async {
    var app = c.app(utils.uniqueName('app'));
    await app.create(utils.emptyPerms());
    var db = app.noSqlDatabase(utils.uniqueName('db'));
    await db.create(utils.emptyPerms());

    var tableNames = [utils.uniqueName('table1'), utils.uniqueName('table2')];
    tableNames.sort();

    for (var tableName in tableNames) {
      await db.table(tableName).create(utils.emptyPerms());
    }

    var tables = await db.listTables();
    tables.sort((t1, t2) => t1.name.compareTo(t2.name));
    expect(tables.length, equals(tableNames.length));
    for (var i = 0; i < tableNames.length; i++) {
      expect(tables[i].name, equals(tableNames[i]));
    }
  });

  test('basic watch', () async {
    var app = c.app(utils.uniqueName('app'));
    await app.create(utils.emptyPerms());
    var db = app.noSqlDatabase(utils.uniqueName('db'));
    await db.create(utils.emptyPerms());
    var table = db.table(utils.uniqueName('table'));
    await table.create(utils.emptyPerms());

    // Perform some operations that we won't be watching.
    await table.put('row1', UTF8.encode('value1'));
    await table.delete('row1');

    // Start watching everything from now.
    var resumeMarker = await db.getResumeMarker();
    var prefix = '';
    var watchStream = db.watch(table.name, prefix, resumeMarker);

    // Perform some operations while are watching.
    var expectedChanges = new List<WatchChange>();

    await table.put('row2', UTF8.encode('value2'));
    resumeMarker = await db.getResumeMarker();
    var expectedChange = SyncbaseClient.watchChange(
        table.name, 'row2', resumeMarker, WatchChangeTypes.put,
        valueBytes: UTF8.encode('value2'));
    expectedChanges.add(expectedChange);

    await table.delete('row2');
    resumeMarker = await db.getResumeMarker();
    expectedChange = SyncbaseClient.watchChange(
        table.name, 'row2', resumeMarker, WatchChangeTypes.delete);
    expectedChanges.add(expectedChange);

    // Ensure we see all the expected changes in order in the watch stream.
    var changeNum = 0;
    await for (var change in watchStream) {
      // Classes generated by mojom Dart compiler do not override == and hashCode
      // but they do override toString to print all properties. So we use toString
      // to assert equality.
      expect(change.toString(), equals(expectedChanges[changeNum].toString()));
      changeNum++;
      // We need to break out of awaiting for watch stream values when we get everything we expected.
      // because watch stream does not end until canceled by design and we don't have canceling mechanism yet.
      if (changeNum == expectedChanges.length) {
        break;
      }
    }
  });

  test('watch flow control', () async {
    var app = c.app(utils.uniqueName('app'));
    await app.create(utils.emptyPerms());
    var db = app.noSqlDatabase(utils.uniqueName('db'));
    await db.create(utils.emptyPerms());
    var table = db.table(utils.uniqueName('table'));
    await table.create(utils.emptyPerms());

    var resumeMarker = await db.getResumeMarker();
    var aFewMoments = new Duration(seconds: 1);
    const int numOperations = 10;
    var allOperations = [];

    // Do several put operations in parallel and wait until they are all done.
    for (var i = 0; i < numOperations; i++) {
      allOperations.add(table.put('row $i', UTF8.encode('value$i')));
    }
    await Future.wait(allOperations);

    // Reset testing instrumentations.
    testing.DatabaseWatch.onChangeCounter.reset();

    // Create a watch stream.
    var watchStream = db.watch(table.name, '', resumeMarker);

    // Listen for the data on the stream.
    var allExpectedChangesReceived = new Completer();
    onData(_) {
      if (testing.DatabaseWatch.onChangeCounter.count == numOperations) {
        allExpectedChangesReceived.complete();
      }
    }
    var streamListener = watchStream.listen(onData);

    // Pause the stream.
    streamListener.pause();

    // Wait a few moments.
    await new Future.delayed(aFewMoments);

    // Assert that we did not got any* events from server when paused.
    // testing.DatabaseWatch.onChangeCounter instrumentation is used to ensure
    // that client did not receive any updates from mojo server, guaranteeing
    // flow control propagated properly all the way to the other end of the pipe
    // *Note: We always get 1 change before we can tell the server to block by
    // not acking that single change.
    expect(testing.DatabaseWatch.onChangeCounter.count, equals(1));

    // Resume the stream.
    streamListener.resume();

    // Wait until we get all expected changes.
    await allExpectedChangesReceived.future;

    // Assert we've got all the expected changes after resuming.
    expect(testing.DatabaseWatch.onChangeCounter.count, equals(numOperations));
  });

  test('basic exec', () async {
    var app = c.app(utils.uniqueName('app'));
    await app.create(utils.emptyPerms());
    var db = app.noSqlDatabase(utils.uniqueName('db'));
    await db.create(utils.emptyPerms());
    var table = db.table('airports');
    await table.create(utils.emptyPerms());

    await table.put('aӲ읔', UTF8.encode('ᚸӲ읔+קAل'));
    await table.put('yyz', UTF8.encode('Toronto'));

    var query = 'select k as code, v as cityname from airports';
    var resultStream = db.exec(query);

    var results = await resultStream.toList();

    // Expect first entry to be column headers.
    var headers = results[0].values;
    expect(headers, equals([UTF8.encode('"code"'), UTF8.encode('"cityname"')]));

    // Expect the two entries
    var entry1 = results[1].values;
    expect(entry1, equals([UTF8.encode('"aӲ읔"'), UTF8.encode('ᚸӲ읔+קAل')]));

    var entry2 = results[2].values;
    expect(entry2, equals([UTF8.encode('"yyz"'), UTF8.encode('Toronto')]));

    // Expect no more entries than two data rows and one column header.
    expect(results.length, 3);
  });

  // TODO(nlacasse): Test database.get/setPermissions.
}
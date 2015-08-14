#!mojo mojo:dart_content_handler
import 'dart:async';

import 'package:mojo/core.dart' show MojoHandle;
import 'package:test/test.dart';

import 'package:ether/initialized_application.dart' show InitializedApplication;
import 'package:ether/syncbase_client.dart' show SyncbaseClient;

// Import other test files.
import './syncbase_app_test.dart' show runAppTests;
import './syncbase_database_test.dart' show runDatabaseTests;
import './syncbase_row_test.dart' show runRowTests;
import './syncbase_table_test.dart' show runTableTests;

main(List args) async {
  InitializedApplication app = new InitializedApplication.fromHandle(args[0]);
  await app.initialized;

  String url = 'https://mojo.v.io/syncbase_server.mojo';

  SyncbaseClient c = new SyncbaseClient(app, url);

  tearDown(() {
    app.resetConnections();
  });

  // Run imported tests.
  runAppTests(c);
  runDatabaseTests(c);
  runTableTests(c);
  runRowTests(c);

  // Append a final test to terminate shell connection.
  // TODO(nlacasse): Remove this once package 'test' supports a global tearDown
  // callback.  See https://github.com/dart-lang/test/issues/18.
  test('terminate shell connection', () async {
    await c.close();
    expect(MojoHandle.reportLeakedHandles(), isTrue);

    // TODO(nlacasse): When running mojo_shell with --enable-multiprocess,
    // closing the application causes a non-graceful shutdown.  To avoid this,
    // we sleep for a second so the test reporter can finish and print the
    // results before we close the app.  Once mojo_shell can shut down more
    // gracefully, we should call app.close directly in the test and not in
    // this Timer.
    new Timer(new Duration(seconds: 1), app.close);
  });
}

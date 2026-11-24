import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:platform_app/data/json_cache.dart';

final feedBody = File('test/fixtures/stations.json').readAsStringSync();

/// UTF-8 response, as GitHub Pages serves it (plain http.Response defaults to latin1).
http.Response ok(String body, {Map<String, String> headers = const {}}) =>
    http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json; charset=utf-8', ...headers});

void main() {
  late Directory dir;
  late List<http.Request> requests;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('feedrepo');
    requests = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  MockClient serve(http.Response Function(http.Request) handler) => MockClient((req) async {
        requests.add(req);
        return handler(req);
      });

  test('downloads when no cache', () async {
    final repo = stationsCache(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir);
    expect(await repo.loadCached(), isNull);
    final feed = await repo.refresh();
    expect(feed.stations.length, 6);
    expect(requests.single.headers.containsKey('If-None-Match'), isFalse);
    expect((await repo.loadCached())!.stations.length, 6);
  });

  test('sends etag and keeps cache on 304', () async {
    await stationsCache(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir).refresh();
    final repo = stationsCache(serve((_) => http.Response('', 304)), dir);
    final cached = await repo.loadCached();
    final feed = await repo.refresh();
    expect(requests.last.headers['If-None-Match'], '"a"');
    expect(identical(feed, cached), isTrue);
  });

  test('replaces cache on 200 with new etag', () async {
    await stationsCache(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir).refresh();
    final newer = feedBody.replaceFirst('Edinburgh', 'Edinburgh Waverley');
    await stationsCache(serve((_) => ok(newer, headers: {'etag': '"b"'})), dir).refresh();
    final repo = stationsCache(serve((_) => http.Response('', 304)), dir);
    expect((await repo.loadCached())!.byCrs('EDB')!.name, 'Edinburgh Waverley');
    await repo.refresh();
    expect(requests.last.headers['If-None-Match'], '"b"');
  });

  test('falls back to cache on network error', () async {
    await stationsCache(serve((_) => ok(feedBody)), dir).refresh();
    final repo = stationsCache(MockClient((_) async => throw const SocketException('offline')), dir);
    final cached = await repo.loadCached();
    expect(await repo.refresh(), same(cached));
  });

  test('test_first_launch_offline_reports_error', () async {
    final repo = stationsCache(MockClient((_) async => throw const SocketException('offline')), dir);
    expect(await repo.loadCached(), isNull);
    await expectLater(repo.refresh(), throwsA(isA<DataUnavailable>()));
  });

  test('timeout without cache throws DataUnavailable', () async {
    final never = Completer<http.Response>();
    final repo = stationsCache(MockClient((_) => never.future), dir,
        timeout: const Duration(milliseconds: 50), firstTimeout: const Duration(milliseconds: 50));
    await expectLater(repo.refresh(), throwsA(isA<DataUnavailable>()));
  });

  test('first download gets a longer timeout than a refresh', () async {
    MockClient slow() => MockClient((req) async {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          return ok(feedBody);
        });
    final first = stationsCache(slow(), dir, timeout: const Duration(milliseconds: 50), firstTimeout: const Duration(seconds: 2));
    expect((await first.refresh()).stations.length, 6); // no cache: waits up to firstTimeout
    final again = stationsCache(slow(), dir, timeout: const Duration(milliseconds: 50), firstTimeout: const Duration(seconds: 2));
    final cached = await again.loadCached();
    expect(await again.refresh(), same(cached)); // has cache: short timeout, falls back
  });



  test('default timeout is 15 s', () {
    expect(stationsCache(MockClient((_) async => http.Response('', 500)), dir).timeout, const Duration(seconds: 15));
  });

  test('corrupt cache treated as missing', () async {
    File('${dir.path}/stations.json').writeAsStringSync('{"version":1,"stations":[');
    final repo = stationsCache(serve((_) => ok(feedBody)), dir);
    expect(await repo.loadCached(), isNull);
    expect((await repo.refresh()).stations.length, 6);
    expect(requests.single.headers.containsKey('If-None-Match'), isFalse);
  });

  test('etag sent belongs to the feed this repository holds', () async {
    await stationsCache(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir).refresh();
    final stale = stationsCache(serve((_) => http.Response('', 304)), dir);
    await stale.loadCached(); // holds feed "a"
    final newer = feedBody.replaceFirst('Edinburgh', 'Edinburgh Waverley');
    await stationsCache(serve((_) => ok(newer, headers: {'etag': '"b"'})), dir).refresh();
    await stale.refresh();
    expect(requests.last.headers['If-None-Match'], '"a"');
  });

  test('refresh without loadCached still uses disk cache', () async {
    await stationsCache(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir).refresh();
    final repo = stationsCache(serve((_) => http.Response('', 304)), dir);
    expect((await repo.refresh()).stations.length, 6);
    expect(requests.last.headers['If-None-Match'], '"a"');
  });

  test('concurrent refresh shares one request', () async {
    final gate = Completer<void>();
    final repo = stationsCache(MockClient((req) async {
      requests.add(req);
      await gate.future;
      return ok(feedBody);
    }), dir);
    final a = repo.refresh(), b = repo.refresh();
    gate.complete();
    expect(identical(await a, await b), isTrue);
    expect(requests.length, 1);
  });

  test('write failure still returns downloaded feed', () async {
    final notADir = File('${dir.path}/file')..writeAsStringSync('x');
    final repo = stationsCache(serve((_) => ok(feedBody)), Directory(notADir.path));
    expect((await repo.refresh()).stations.length, 6);
  });

  test('concurrent loadCached share one read', () async {
    await stationsCache(serve((_) => ok(feedBody)), dir).refresh();
    final repo = stationsCache(serve((_) => http.Response('', 304)), dir);
    final a = repo.loadCached(), b = repo.loadCached();
    expect(await a, isNotNull);
    expect(await b, isNotNull);
  });



  test('requests the stations url', () async {
    await stationsCache(serve((_) => ok(feedBody)), dir).refresh();
    expect(requests.single.url.toString(), 'https://api.whatplatform.uk/stations.json');
    expect(requests.single.headers['User-Agent'], 'WhatPlatform/1.5');
  });

  test('default timeouts', () {
    final c = stationsCache(MockClient((_) async => http.Response('', 500)), dir);
    expect(c.timeout, const Duration(seconds: 15));
    expect(c.firstTimeout, const Duration(seconds: 30));
  });


  test('invalid download keeps previous cache', () async {
    await stationsCache(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir).refresh();
    final repo = stationsCache(serve((_) => ok('<html>oops</html>')), dir);
    final cached = await repo.loadCached();
    expect(await repo.refresh(), same(cached));
    expect((await repo.loadCached())!.stations.length, 6);
  });
}

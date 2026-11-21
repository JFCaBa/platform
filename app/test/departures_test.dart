import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:platform_app/config.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/domain/position.dart';

final boardBody = File('test/fixtures/board_kgx.json').readAsStringSync();

http.Response okJson(String body) =>
    http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  test('Board.fromJson on the API fixture', () {
    final raw = jsonDecode(boardBody) as Map<String, dynamic>;
    final b = Board.fromJson(raw);
    expect(b.crs, 'KGX');
    expect(b.name, 'London Kings Cross');
    expect(b.generatedAt.isUtc, isTrue);
    expect(b.generatedAt, DateTime.parse(raw['generatedAt'] as String));
    expect(b.attribution, 'Data: National Rail');
    expect(b.nrccMessages, isNotEmpty);
    expect(b.services.length, 20);
    final first = b.services.first;
    final s0 = (raw['services'] as List).first as Map<String, dynamic>;
    expect(first.std, s0['std']);
    expect(first.etd, s0['etd']);
    expect(first.destination, s0['destination']);
    expect(b.services.where((s) => s.cancelled), isNotEmpty);
  });

  test('nullable fields', () {
    final b = Board.fromJson({
      'crs': 'BKM',
      'name': null,
      'generatedAt': '2026-11-16T23:58:00Z',
      'nrccMessages': [],
      'attribution': 'Data: National Rail',
      'services': [
        {'std': '23:58', 'etd': null, 'platform': null, 'destination': 'Euston', 'via': null, 'operator': null,
         'cancelled': false, 'delayReason': null, 'cancelReason': null},
      ],
    });
    final d = b.services.single;
    expect(b.name, isNull);
    expect([d.etd, d.platform, d.via, d.operator, d.delayReason, d.cancelReason], everyElement(isNull));
    expect(d.destination, 'Euston');
  });

  test('serviceId is read when present', () {
    final b = Board.fromJson({'crs': 'KGX', 'generatedAt': '2026-11-16T23:58:00Z', 'nrccMessages': [],
        'attribution': 'x', 'services': [
          {'std': '14:36', 'destination': 'Cambridge', 'cancelled': false, 'serviceId': '10741504KNGX____'},
          {'std': '14:40', 'destination': 'Harrogate', 'cancelled': false},
        ]});
    expect(b.services.map((d) => d.serviceId), ['10741504KNGX____', null]);
  });

  test('empty board', () {
    final b = Board.fromJson({'crs': 'BKM', 'name': 'Berkhamsted', 'generatedAt': '2026-11-16T23:58:00Z',
        'nrccMessages': [], 'attribution': 'Data: National Rail', 'services': []});
    expect(b.services, isEmpty);
  });

  group('fetch', () {
    late List<http.Request> requests;
    DeparturesClient client(Future<http.Response> Function(http.Request) handler) =>
        DeparturesClient(MockClient((req) {
          requests.add(req);
          return handler(req);
        }));
    setUp(() => requests = []);

    test('200 → Board, URL and User-Agent', () async {
      final b = await client((_) async => okJson(boardBody)).fetch('KGX');
      expect(b.services.length, 20);
      expect(requests.single.url.toString(), '$apiBaseUrl/departures/KGX');
      expect(requests.single.headers['User-Agent'], 'WhatPlatform/1.2');
    });

    test('429 → RateLimited (only Darwin asking us to slow down)', () async {
      await expectLater(client((_) async => http.Response('', 429)).fetch('KGX'), throwsA(isA<RateLimited>()));
    });

    test('500, 502, 503, 404 → DeparturesUnavailable', () async {
      for (final code in [500, 502, 503, 404]) {
        await expectLater(client((_) async => http.Response('', code)).fetch('KGX'), throwsA(isA<DeparturesUnavailable>()));
      }
    });

    test('invalid JSON or wrong shape → DeparturesUnavailable', () async {
      for (final body in ['<html>', '[]', '{"crs":"KGX"}']) {
        await expectLater(client((_) async => okJson(body)).fetch('KGX'), throwsA(isA<DeparturesUnavailable>()), reason: body);
      }
    });

    test('network error and timeout → DeparturesUnavailable', () async {
      await expectLater(client((_) async => throw const SocketException('offline')).fetch('KGX'),
          throwsA(isA<DeparturesUnavailable>()));
      final slow = DeparturesClient(MockClient((_) => Future.delayed(const Duration(seconds: 1), () => okJson(boardBody))),
          timeout: const Duration(milliseconds: 50));
      await expectLater(slow.fetch('KGX'), throwsA(isA<DeparturesUnavailable>()));
    });
  });

  group('fetchStops', () {
    const body = '{"generatedAt":"2026-11-17T14:25:19Z","attribution":"Data: National Rail","portions":[['
        '{"name":"Finsbury Park","crs":"FPK","st":"14:41","et":"On time","cancelled":false},'
        '{"name":"Hitchin","crs":"HIT","st":"15:25","et":"15:31","cancelled":false},'
        '{"name":"Royston","crs":"RYS","st":"15:42","et":"Cancelled","cancelled":true}],'
        '[{"name":"Arlesey","crs":"ARL","st":"15:30","et":null,"cancelled":false}]]}';

    test('200 → stops, URL escapes the id', () async {
      final requests = <http.Request>[];
      final c = DeparturesClient(MockClient((req) async {
        requests.add(req);
        return okJson(body);
      }));
      final s = await c.fetchStops('10741504KNGX____');
      expect(requests.single.url.toString(), '$apiBaseUrl/service/10741504KNGX____');
      expect(s.length, 2);
      expect(s[1].single.name, 'Arlesey');
      expect(s[0].map((x) => (x.name, x.st, x.et, x.cancelled)).toList(), [
        ('Finsbury Park', '14:41', 'On time', false),
        ('Hitchin', '15:25', '15:31', false),
        ('Royston', '15:42', 'Cancelled', true),
      ]);
    });

    test('fetchService: stops and where the train is', () async {
      final withPos = body.replaceFirst('"portions"', '"position":{"lastStop":"Hitchin","lastAt":"15:26","stopsAway":2},"portions"');
      final s = await DeparturesClient(MockClient((_) async => okJson(withPos))).fetchService('10741504KNGX____');
      expect(s.portions.length, 2);
      expect(s.position, const PassedStop('Hitchin', '15:26', 2));
      final old = await DeparturesClient(MockClient((_) async => okJson(body))).fetchService('10741504KNGX____');
      expect(old.position, isNull);
    });

    test('any failure → DeparturesUnavailable', () async {
      for (final r in [http.Response('', 404), http.Response('', 503), okJson('{"portions":[[{"name":1}]]}'), okJson('[]')]) {
        await expectLater(DeparturesClient(MockClient((_) async => r)).fetchStops('10741504KNGX____'),
            throwsA(isA<DeparturesUnavailable>()));
      }
    });
  });
}

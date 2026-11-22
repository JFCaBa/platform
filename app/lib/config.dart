const stationsUrl = 'https://jfcaba.github.io/platform/stations.json';
/// Overridable only for end-to-end tests against a local fake API (--dart-define=API_BASE_URL=...).
const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'https://api.whatplatform.uk');
const privacyUrl = 'https://whatplatform.uk/';
const userAgent = 'WhatPlatform/1.5';

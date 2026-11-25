/// Overridable only for end-to-end tests against a local fake API (--dart-define=API_BASE_URL=...).
const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'https://api.whatplatform.uk');
/// GB station list, rebuilt monthly on our server (platform repo, deploy/stations/).
const stationsUrl = '$apiBaseUrl/stations.json';
const privacyUrl = 'https://whatplatform.uk/privacy';
const userAgent = 'WhatPlatform/1.5';

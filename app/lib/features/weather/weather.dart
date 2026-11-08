/// Overlay variant drawn above the user.
enum WeatherVisual { sun, partlyCloudy, cloud, rain, storm, fog, snow }

class Weather {
  const Weather({
    required this.temperatureC,
    required this.humidityPct,
    required this.windKmh,
    required this.rainPct,
    required this.code,
    required this.observedAt,
  });

  final double temperatureC;
  final int humidityPct;
  final double windKmh;
  final int rainPct;

  /// WMO weather interpretation code.
  final int code;
  final DateTime observedAt;

  String get label => weatherLabel(code);
  WeatherVisual get visual => weatherVisual(code);
}

String weatherLabel(int code) {
  switch (code) {
    case 0:
      return 'Clear Sky';
    case 1:
      return 'Mainly Clear';
    case 2:
      return 'Partly Cloudy';
    case 3:
      return 'Overcast';
    case 45:
    case 48:
      return 'Fog';
    case 51:
    case 53:
    case 55:
      return 'Drizzle';
    case 56:
    case 57:
      return 'Freezing Drizzle';
    case 61:
    case 63:
    case 65:
      return 'Rain';
    case 66:
    case 67:
      return 'Freezing Rain';
    case 71:
    case 73:
    case 75:
    case 77:
      return 'Snow';
    case 80:
    case 81:
    case 82:
      return 'Rain Showers';
    case 85:
    case 86:
      return 'Snow Showers';
    case 95:
      return 'Thunderstorm';
    case 96:
    case 99:
      return 'Thunderstorm, Hail';
    default:
      return 'Unknown';
  }
}

WeatherVisual weatherVisual(int code) {
  if (code == 0 || code == 1) return WeatherVisual.sun;
  if (code == 2) return WeatherVisual.partlyCloudy;
  if (code == 3) return WeatherVisual.cloud;
  if (code == 45 || code == 48) return WeatherVisual.fog;
  if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) return WeatherVisual.rain;
  if ((code >= 71 && code <= 77) || code == 85 || code == 86) return WeatherVisual.snow;
  if (code >= 95) return WeatherVisual.storm;
  return WeatherVisual.partlyCloudy;
}

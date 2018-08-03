import 'dart:async';

/// The utility functions for the client.
Stream<T> merge<T>(List<Stream<T>> streams) {
  int _open = streams.length;
  var c = new StreamController<T>();
  for (var stream in streams) {
    stream.listen(c.add)
      ..onError(c.addError)
      ..onDone(() {
        if (--_open == 0) {
          c.close();
        }
      });
  }
  return c.stream;
}

int RGBtoInt(String RGB) {
  int R = int.parse(RGB.substring(0, 3), radix: 16);
  int G = int.parse(RGB.substring(3, 5), radix: 16);
  int B = int.parse(RGB.substring(5), radix: 16);

  return B * 65536 + G * 256 + R;
}

Iterable<String> split(String str, int length) sync* {
  int last = 0;
  while (last < str.length && ((last + length) < str.length)) {
    yield str.substring(last, last + length);
    last += length;
  }
  yield str.substring(last, str.length);
}

Iterable<String> splitEqually(String str, int pieces) {
  int len = (str.length / pieces).round();

  return split(str, len);
}
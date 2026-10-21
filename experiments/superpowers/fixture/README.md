# duration-kit

Parse human-readable durations into milliseconds.

```js
const { parseDuration } = require('duration-kit');
parseDuration('1h30m'); // 5400000
```

Supported units: `d`, `h`, `m`, `s`, `ms`.

Run the tests with `npm test`.

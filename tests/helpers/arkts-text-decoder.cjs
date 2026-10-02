const { TextDecoder } = require('node:util');

module.exports = {
  TextDecoder: {
    create(encoding, options) {
      const decoder = new TextDecoder(encoding, options);
      return { decodeToString(bytes, decodeOptions) { return decoder.decode(bytes, decodeOptions); } };
    },
  },
};

// Learn more: https://docs.expo.dev/guides/customizing-metro/
const { getDefaultConfig } = require('expo/metro-config');

const config = getDefaultConfig(__dirname);

// Sample books and the reader runtime ship as plain assets.
config.resolver.assetExts.push('epub', 'txt');

module.exports = config;

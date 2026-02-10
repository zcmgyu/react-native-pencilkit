// Reexport the native module. On web, it will be resolved to ReactNativePencilKitModule.web.ts
// and on native platforms to ReactNativePencilKitModule.ts
export { default } from './ReactNativePencilKitModule';
export { default as ReactNativePencilKitView } from './ReactNativePencilKitView';
export * from  './ReactNativePencilKit.types';

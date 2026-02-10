import { NativeModule, requireNativeModule } from 'expo';

import { ReactNativePencilKitModuleEvents } from './ReactNativePencilKit.types';

declare class ReactNativePencilKitModule extends NativeModule<ReactNativePencilKitModuleEvents> {
  PI: number;
  hello(): string;
  setValueAsync(value: string): Promise<void>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ReactNativePencilKitModule>('ReactNativePencilKit');

import { registerWebModule, NativeModule } from 'expo';

import { ReactNativePencilKitModuleEvents } from './ReactNativePencilKit.types';

class ReactNativePencilKitModule extends NativeModule<ReactNativePencilKitModuleEvents> {
  PI = Math.PI;
  async setValueAsync(value: string): Promise<void> {
    this.emit('onChange', { value });
  }
  hello() {
    return 'Hello world! 👋';
  }
}

export default registerWebModule(ReactNativePencilKitModule, 'ReactNativePencilKitModule');

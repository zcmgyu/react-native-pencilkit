import { requireNativeView } from 'expo';
import * as React from 'react';

import { ReactNativePencilKitViewProps } from './ReactNativePencilKit.types';

const NativeView: React.ComponentType<ReactNativePencilKitViewProps> =
  requireNativeView('ReactNativePencilKit');

export default function ReactNativePencilKitView(props: ReactNativePencilKitViewProps) {
  return <NativeView {...props} />;
}

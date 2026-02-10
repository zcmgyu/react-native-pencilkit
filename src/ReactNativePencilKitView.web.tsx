import * as React from 'react';

import { ReactNativePencilKitViewProps } from './ReactNativePencilKit.types';

export default function ReactNativePencilKitView(props: ReactNativePencilKitViewProps) {
  return (
    <div>
      <iframe
        style={{ flex: 1 }}
        src={props.url}
        onLoad={() => props.onLoad({ nativeEvent: { url: props.url } })}
      />
    </div>
  );
}

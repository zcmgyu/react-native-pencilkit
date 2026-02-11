import React, { useImperativeHandle, useRef } from "react";
import { PencilKitViewProps, PencilKitViewRef, ToolConfig } from './ReactNativePencilKit.types';

import {
  requireNativeModule,
  requireNativeViewManager,
} from "expo-modules-core";
import { Platform, findNodeHandle } from "react-native";

let ReactNativePencilKit: any | null = null;
let ReactNativePencilKitViewManager: any | null = null;

if (Platform.OS === "ios") {
  ReactNativePencilKit = requireNativeModule("ReactNativePencilKitModule");
  ReactNativePencilKitViewManager = requireNativeViewManager(
    "ReactNativePencilKitModule"
  );
}


/**
 * PencilKit View Component
 */
export const PencilKitView = React.forwardRef<
  PencilKitViewRef,
  PencilKitViewProps
>((props, ref) => {
  const viewRef = useRef<any>(null);

  useImperativeHandle(
    ref,
    () => ({
      setupToolPicker: async (toolConfig?: ToolConfig) => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            // Convert ToolConfig to the format expected by native module
            const nativeToolConfig = toolConfig ? {
              type: toolConfig.type,
              width: toolConfig.width,
              color: toolConfig.color,
              eraserType: toolConfig.eraserType,
              fallbackTool: toolConfig.fallbackTool,
            } : null;
            await ReactNativePencilKit.setupToolPicker(viewTag, nativeToolConfig);
          }
        }
      },
      clearDrawing: async () => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            await ReactNativePencilKit.clearDrawing(viewTag);
          }
        }
      },
      undo: async () => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            await ReactNativePencilKit.undo(viewTag);
          }
        }
      },
      redo: async () => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            await ReactNativePencilKit.redo(viewTag);
          }
        }
      },
      captureDrawing: async (): Promise<string> => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            return await ReactNativePencilKit.captureDrawing(viewTag);
          }
        }
        return "";
      },
      getCanvasDataAsBase64: async (): Promise<string> => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            return await ReactNativePencilKit.getCanvasDataAsBase64(viewTag);
          }
        }
        return "";
      },
      setCanvasDataFromBase64: async (
        base64String: string
      ): Promise<boolean> => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            return await ReactNativePencilKit.setCanvasDataFromBase64(
              viewTag,
              base64String
            );
          }
        }
        return false;
      },
      canUndo: async (): Promise<boolean> => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            return await ReactNativePencilKit.canUndo(viewTag);
          }
        }
        return false;
      },
      canRedo: async (): Promise<boolean> => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            return await ReactNativePencilKit.canRedo(viewTag);
          }
        }
        return false;
      },
      setCanvasBackgroundColor: async (colorString: string) => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            await ReactNativePencilKit.setCanvasBackgroundColor(
              viewTag,
              colorString
            );
          }
        }
      },
      getCanvasBackgroundColor: async (): Promise<string> => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            return await ReactNativePencilKit.getCanvasBackgroundColor(
              viewTag
            );
          }
        }
        return "#FFFFFF";
      },
      showColorPicker: async () => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            await ReactNativePencilKit.showColorPicker(viewTag);
          }
        }
      },
    }),
    []
  );

  if (Platform.OS !== "ios" || !ReactNativePencilKitViewManager) {
    return null;
  }

  return React.createElement(ReactNativePencilKitViewManager, {
    ...props,
    ref: viewRef,
  });
});

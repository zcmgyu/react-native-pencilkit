import {
  FontAwesome5,
  MaterialCommunityIcons,
} from "@expo/vector-icons";
import * as ImagePicker from "expo-image-picker";
import {
  CanRedoChangedEvent,
  CanUndoChangedEvent,
  DrawChangeEvent,
  DrawEndEvent,
  DrawStartEvent,
  NativeEvent,
  PencilKitView,
  PencilKitViewRef,
} from "react-native-pencilkit";
import React, { useEffect, useRef, useState } from "react";
import {
  Alert,
  Dimensions,
  Image,
  Pressable,
  SafeAreaView,
  ScrollView,
  Share,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";

const { width: screenWidth } = Dimensions.get("window");
const CANVAS_SIZE = Math.min(screenWidth - 40, 360);
const HIT_SLOP = { top: 12, bottom: 12, left: 12, right: 12 };

// Sketchbook-inspired palette
const COLORS = {
  paper: "#f8f6f2",
  paperDark: "#ebe7e0",
  ink: "#2d2a26",
  inkMuted: "#6b6560",
  accent: "#b87333",
  accentLight: "#d4a574",
  surface: "#ffffff",
  border: "#e0dbd4",
  success: "#4a7c59",
  danger: "#c45c4a",
};

export default function App() {
  const pencilKitRef = useRef<PencilKitViewRef>(null);

  const [canUndoState, setCanUndoState] = useState(false);
  const [canvasRerenderKey, setCanvasRerenderKey] = useState(0);
  const [canRedoState, setCanRedoState] = useState(false);
  const [isDrawing, setIsDrawing] = useState(false);
  const [backgroundColor, setBackgroundColor] = useState("");
  const [backgroundColorInput, setBackgroundColorInput] = useState("FFFFFF");
  const [backgroundImage, setBackgroundImage] = useState<string | null>(null);
  const [savedCanvasData, setSavedCanvasData] = useState("");

  useEffect(() => {
    const setupTimer = setTimeout(() => {
      if (pencilKitRef.current) {
        // Set watercolor as default tool with marker as fallback
        // Falls back to: watercolor -> marker -> pen (if watercolor not available on iOS < 17)
        pencilKitRef.current.setupToolPicker({
          type: "watercolor",
          fallbackTool: "marker",
          width: 20.0,
          color: "#FF0000",
        });
      }
    }, 100);

    const getInitialBgColor = async () => {
      if (pencilKitRef.current) {
        try {
          const bgColor =
            await pencilKitRef.current.getCanvasBackgroundColor();
          setBackgroundColor(bgColor);
          setBackgroundColorInput(bgColor);
        } catch (_) {}
      }
    };

    setTimeout(getInitialBgColor, 200);

    return () => {
      clearTimeout(setupTimer);
    };
  }, []);

  const handleDrawStart = (_event: NativeEvent<DrawStartEvent>) => {
    setIsDrawing(true);
  };

  const handleDrawEnd = (_event: NativeEvent<DrawEndEvent>) => {
    setIsDrawing(false);
  };

  const handleDrawChange = (event: NativeEvent<DrawChangeEvent>) => {
    console.log("Draw Change", event.nativeEvent.data);
  };

  const handleCanUndoChanged = (event: NativeEvent<CanUndoChangedEvent>) => {
    setCanUndoState(event.nativeEvent.canUndo);
  };

  const handleCanRedoChanged = (event: NativeEvent<CanRedoChangedEvent>) => {
    setCanRedoState(event.nativeEvent.canRedo);
  };

  const handleUndo = () => {
    pencilKitRef.current?.undo();
  };

  const handleRedo = () => {
    pencilKitRef.current?.redo();
  };

  const handleClear = () => {
    pencilKitRef.current?.clearDrawing();
  };

  const handleShowColorPicker = () => {
    pencilKitRef.current?.showColorPicker();
  };

  const handleSetBackgroundColor = async () => {
    if (pencilKitRef.current && backgroundColorInput) {
      try {
        pencilKitRef.current.setCanvasBackgroundColor(backgroundColorInput);
        setBackgroundColor(backgroundColorInput);
      } catch (_) {}
    }
  };

  const handleGetBackgroundColor = async () => {
    if (pencilKitRef.current) {
      try {
        const color = await pencilKitRef.current.getCanvasBackgroundColor();
        setBackgroundColor(color);
        setBackgroundColorInput(color);
      } catch (_) {}
    }
  };

  const handlePickImage = async () => {
    try {
      const permissionResult =
        await ImagePicker.requestMediaLibraryPermissionsAsync();

      if (permissionResult.granted === false) {
        Alert.alert(
          "Permission Required",
          "Permission to access camera roll is required."
        );
        return;
      }

      const result = await ImagePicker.launchImageLibraryAsync({
        mediaTypes: ImagePicker.MediaTypeOptions.Images,
        allowsEditing: true,
        aspect: [1, 1],
        quality: 0.8,
      });

      if (!result.canceled && result.assets[0]) {
        setBackgroundImage(result.assets[0].uri);
      }
    } catch (_) {
      Alert.alert("Error", "Failed to pick image");
    }
  };

  const handleRemoveBackgroundImage = () => {
    setBackgroundImage(null);
    setCanvasRerenderKey((prev) => prev + 1);
  };

  const handleSaveCanvasData = async () => {
    if (pencilKitRef.current) {
      try {
        const data = await pencilKitRef.current.getCanvasDataAsBase64();
        setSavedCanvasData(data);
        Alert.alert(
          "Saved",
          `Canvas data saved (${Math.round(data.length / 1024)} KB)`
        );
      } catch (_) {
        Alert.alert("Error", "Failed to save canvas data");
      }
    }
  };

  const handleExportImage = async () => {
    if (pencilKitRef.current) {
      try {
        const imageData = await pencilKitRef.current.captureDrawing();
        await Share.share({
          title: "PencilKit Drawing",
          message: "Check out my drawing!",
          url: `data:image/png;base64,${imageData}`,
        });
      } catch (_) {
        Alert.alert("Error", "Failed to export and share image");
      }
    }
  };

  return (
    <SafeAreaView style={styles.container}>
      <ScrollView
        style={styles.scrollView}
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        <View style={styles.header}>
          <Text style={styles.title}>PencilKit</Text>
          <Text style={styles.subtitle}>Draw on the canvas below</Text>
        </View>

        {/* Canvas – hero section */}
        <View style={styles.canvasSection}>
          <View style={styles.canvasFrame}>
            <View style={styles.toolbar}>
              <View style={styles.statusPill}>
                <View
                  style={[
                    styles.statusDot,
                    isDrawing && styles.statusDotActive,
                  ]}
                />
                <Text style={styles.statusLabel}>
                  {isDrawing ? "Drawing" : "Idle"}
                </Text>
              </View>
              <View style={styles.toolbarActions}>
                <Pressable
                  style={[
                    styles.toolButton,
                    !canUndoState && styles.toolButtonDisabled,
                  ]}
                  onPress={handleUndo}
                  disabled={!canUndoState}
                  hitSlop={HIT_SLOP}
                >
                  <FontAwesome5 name="undo" size={14} color={COLORS.surface} />
                </Pressable>
                <Pressable
                  style={[
                    styles.toolButton,
                    !canRedoState && styles.toolButtonDisabled,
                  ]}
                  onPress={handleRedo}
                  disabled={!canRedoState}
                  hitSlop={HIT_SLOP}
                >
                  <FontAwesome5 name="redo" size={14} color={COLORS.surface} />
                </Pressable>
                <Pressable
                  style={styles.toolButton}
                  onPress={handleShowColorPicker}
                  hitSlop={HIT_SLOP}
                >
                  <FontAwesome5 name="palette" size={14} color={COLORS.surface} />
                </Pressable>
                <Pressable
                  style={styles.toolButton}
                  onPress={handleClear}
                  hitSlop={HIT_SLOP}
                >
                  <MaterialCommunityIcons
                    name="eraser"
                    size={14}
                    color={COLORS.surface}
                  />
                </Pressable>
              </View>
            </View>
            <View style={styles.canvasWrapper}>
              <PencilKitView
                key={canvasRerenderKey.toString()}
                ref={pencilKitRef}
                style={styles.canvas}
                imagePath={
                  backgroundImage ? { uri: backgroundImage } : undefined
                }
                onDrawStart={handleDrawStart}
                onDrawEnd={handleDrawEnd}
                onDrawChange={handleDrawChange}
                onCanUndoChanged={handleCanUndoChanged}
                onCanRedoChanged={handleCanRedoChanged}
              />
            </View>
          </View>
        </View>

        {/* Export & share */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Export & share</Text>
          <View style={styles.row}>
            <Pressable
              style={styles.primaryButton}
              onPress={handleSaveCanvasData}
            >
              <FontAwesome5 name="save" size={16} color={COLORS.surface} />
              <Text style={styles.primaryButtonText}>Save data</Text>
            </Pressable>
            <Pressable style={styles.primaryButton} onPress={handleExportImage}>
              <FontAwesome5 name="share-alt" size={16} color={COLORS.surface} />
              <Text style={styles.primaryButtonText}>Share image</Text>
            </Pressable>
          </View>
          {savedCanvasData ? (
            <Text style={styles.hint}>
              Saved data: {Math.round(savedCanvasData.length / 1024)} KB
            </Text>
          ) : null}
        </View>

        {/* Background */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Background</Text>

          <Text style={styles.label}>Image</Text>
          {backgroundImage ? (
            <View style={styles.imageRow}>
              <Image
                source={{ uri: backgroundImage }}
                style={styles.thumb}
                resizeMode="cover"
              />
              <Pressable
                style={styles.removeImageButton}
                onPress={handleRemoveBackgroundImage}
              >
                <FontAwesome5 name="times" size={12} color={COLORS.danger} />
                <Text style={styles.removeImageText}>Remove</Text>
              </Pressable>
            </View>
          ) : (
            <Pressable style={styles.outlineButton} onPress={handlePickImage}>
              <FontAwesome5 name="image" size={16} color={COLORS.accent} />
              <Text style={styles.outlineButtonText}>Pick image</Text>
            </Pressable>
          )}

          <Text style={[styles.label, styles.labelSpaced]}>Color (hex)</Text>
          <View style={styles.colorRow}>
            <View
              style={[
                styles.colorSwatch,
                { backgroundColor: `#${backgroundColorInput || "FFFFFF"}` },
              ]}
            />
            <TextInput
              style={styles.colorInput}
              value={backgroundColorInput}
              onChangeText={setBackgroundColorInput}
              placeholder="FFFFFF"
              placeholderTextColor={COLORS.inkMuted}
              maxLength={6}
              autoCapitalize="characters"
            />
            <Pressable
              style={styles.smallButton}
              onPress={handleSetBackgroundColor}
            >
              <Text style={styles.smallButtonText}>Set</Text>
            </Pressable>
            <Pressable
              style={[styles.smallButton, styles.smallButtonSecondary]}
              onPress={handleGetBackgroundColor}
            >
              <Text style={styles.smallButtonTextSecondary}>Sync</Text>
            </Pressable>
          </View>
          {backgroundColor ? (
            <Text style={styles.hint}>Current: #{backgroundColor}</Text>
          ) : null}
        </View>

        <View style={styles.footer} />
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.paper,
  },
  scrollView: {
    flex: 1,
  },
  scrollContent: {
    paddingHorizontal: 20,
    paddingTop: 16,
    paddingBottom: 100,
  },
  header: {
    marginBottom: 20,
    alignItems: "center",
  },
  title: {
    fontSize: 28,
    fontWeight: "700",
    color: COLORS.ink,
    letterSpacing: -0.5,
  },
  subtitle: {
    fontSize: 15,
    color: COLORS.inkMuted,
    marginTop: 4,
  },
  canvasSection: {
    alignItems: "center",
    marginBottom: 24,
  },
  canvasFrame: {
    width: CANVAS_SIZE + 2,
    borderRadius: 16,
    backgroundColor: COLORS.surface,
    borderWidth: 1,
    borderColor: COLORS.border,
    overflow: "hidden",
    shadowColor: COLORS.ink,
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.06,
    shadowRadius: 12,
    elevation: 4,
  },
  toolbar: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 12,
    paddingVertical: 10,
    backgroundColor: COLORS.paperDark,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
  },
  statusPill: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
  },
  statusDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: COLORS.inkMuted,
  },
  statusDotActive: {
    backgroundColor: COLORS.success,
  },
  statusLabel: {
    fontSize: 13,
    color: COLORS.inkMuted,
    fontWeight: "500",
  },
  toolbarActions: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
  },
  toolButton: {
    width: 36,
    height: 36,
    borderRadius: 18,
    backgroundColor: COLORS.accent,
    justifyContent: "center",
    alignItems: "center",
  },
  toolButtonDisabled: {
    backgroundColor: COLORS.inkMuted,
    opacity: 0.7,
  },
  canvasWrapper: {
    overflow: "hidden",
    borderRadius: 0,
  },
  canvas: {
    width: CANVAS_SIZE,
    height: CANVAS_SIZE,
    backgroundColor: COLORS.surface,
  },
  section: {
    backgroundColor: COLORS.surface,
    borderRadius: 14,
    padding: 18,
    marginBottom: 12,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  sectionTitle: {
    fontSize: 17,
    fontWeight: "600",
    color: COLORS.ink,
    marginBottom: 14,
  },
  label: {
    fontSize: 14,
    fontWeight: "500",
    color: COLORS.inkMuted,
    marginBottom: 8,
  },
  labelSpaced: {
    marginTop: 16,
  },
  row: {
    flexDirection: "row",
    gap: 10,
  },
  primaryButton: {
    flex: 1,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    height: 48,
    borderRadius: 12,
    backgroundColor: COLORS.accent,
  },
  primaryButtonText: {
    fontSize: 15,
    fontWeight: "600",
    color: COLORS.surface,
  },
  outlineButton: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    height: 44,
    borderRadius: 10,
    borderWidth: 1.5,
    borderColor: COLORS.accent,
    backgroundColor: "transparent",
  },
  outlineButtonText: {
    fontSize: 15,
    fontWeight: "500",
    color: COLORS.accent,
  },
  hint: {
    fontSize: 13,
    color: COLORS.inkMuted,
    marginTop: 10,
  },
  imageRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
  },
  thumb: {
    width: 56,
    height: 56,
    borderRadius: 10,
    backgroundColor: COLORS.paperDark,
  },
  removeImageButton: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    paddingVertical: 8,
    paddingHorizontal: 12,
  },
  removeImageText: {
    fontSize: 14,
    color: COLORS.danger,
    fontWeight: "500",
  },
  colorRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
  },
  colorSwatch: {
    width: 36,
    height: 36,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  colorInput: {
    flex: 1,
    height: 44,
    borderWidth: 1,
    borderColor: COLORS.border,
    borderRadius: 10,
    paddingHorizontal: 12,
    fontSize: 15,
    fontFamily: "monospace",
    color: COLORS.ink,
  },
  smallButton: {
    paddingHorizontal: 14,
    height: 44,
    borderRadius: 10,
    backgroundColor: COLORS.accent,
    justifyContent: "center",
    alignItems: "center",
  },
  smallButtonSecondary: {
    backgroundColor: "transparent",
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  smallButtonText: {
    fontSize: 14,
    fontWeight: "600",
    color: COLORS.surface,
  },
  smallButtonTextSecondary: {
    fontSize: 14,
    fontWeight: "500",
    color: COLORS.inkMuted,
  },
  footer: {
    height: 24,
  },
});

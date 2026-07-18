import {
  FontAwesome5,
  MaterialCommunityIcons,
} from "@expo/vector-icons";
import * as ImagePicker from "expo-image-picker";
import {
  BoundaryImageLoadEvent,
  CanRedoChangedEvent,
  CanUndoChangedEvent,
  DrawChangeEvent,
  DrawEndEvent,
  DrawStartEvent,
  NativeEvent,
  PencilKitView,
  PencilKitViewRef,
} from "react-native-pencilkit";
import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  Alert,
  Dimensions,
  Image,
  Pressable,
  SafeAreaView,
  ScrollView,
  Share,
  StatusBar,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  TouchableOpacity,
  useColorScheme,
  View,
} from "react-native";

const { width: screenWidth } = Dimensions.get("window");
const CANVAS_SIZE = Math.min(screenWidth - 40, 360);
const HIT_SLOP = { top: 12, bottom: 12, left: 12, right: 12 };

// Default drawing tool. Falls back: watercolor -> marker -> pen (iOS < 17).
// Shared by initial setup and the full-screen toggle (re-asserted so the native
// PencilKit tool picker stays visible in the new layout).
const DEFAULT_TOOL = {
  type: "watercolor" as const,
  fallbackTool: "marker" as const,
  width: 20.0,
  color: "#FF0000",
};

// Sketchbook-inspired palettes. Selected per device theme via useColorScheme().
type Palette = {
  paper: string;
  paperDark: string;
  ink: string;
  inkMuted: string;
  accent: string;
  accentLight: string;
  surface: string;
  border: string;
  success: string;
  danger: string;
};

const LIGHT: Palette = {
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

const DARK: Palette = {
  paper: "#15130f",       // app background
  paperDark: "#211d18",   // slightly lifted panels (toolbar)
  ink: "#f2ede4",         // primary text
  inkMuted: "#a89f92",    // secondary text / muted icons
  accent: "#d4a574",      // warm copper, brightened for dark bg
  accentLight: "#b87333",
  surface: "#1c1915",     // cards / buttons
  border: "#332e26",
  success: "#6aa77c",
  danger: "#e07a68",
};

export default function App() {
  const pencilKitRef = useRef<PencilKitViewRef>(null);

  // Theme: follow the device light/dark appearance.
  const scheme = useColorScheme();
  const isDark = scheme === "dark";
  const c = isDark ? DARK : LIGHT;
  const styles = useMemo(() => createStyles(c), [c]);

  const [canUndoState, setCanUndoState] = useState(false);
  const [canvasRerenderKey, setCanvasRerenderKey] = useState(0);
  const [canRedoState, setCanRedoState] = useState(false);
  const [isDrawing, setIsDrawing] = useState(false);
  const [backgroundColor, setBackgroundColor] = useState("");
  const [backgroundColorInput, setBackgroundColorInput] = useState("FFFFFF");
  const [backgroundImage, setBackgroundImage] = useState<string | null>(null);
  const [savedCanvasData, setSavedCanvasData] = useState("");
  const [boundaryImage, setBoundaryImage] = useState<string | null>(null);
  const [boundaryColoringEnabled, setBoundaryColoringEnabled] = useState(true);
  const [boundaryDebug, setBoundaryDebug] = useState(false);
  const [boundaryRegionCount, setBoundaryRegionCount] = useState(0);
  const [isFullScreen, setIsFullScreen] = useState(false);

  useEffect(() => {
    const setupTimer = setTimeout(() => {
      if (pencilKitRef.current) {
        pencilKitRef.current.setupToolPicker(DEFAULT_TOOL);
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

  const handleToggleFullScreen = () => {
    setIsFullScreen((prev) => !prev);
    // After the layout settles: re-fit the page to the new size, and re-assert the
    // PencilKit tool picker so its palette stays visible in the new layout (the same
    // native view is reused, so this just re-shows the picker and re-focuses it).
    setTimeout(() => {
      pencilKitRef.current?.resetTransform();
      pencilKitRef.current?.setupToolPicker(DEFAULT_TOOL);
    }, 50);
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

  const handlePickBoundaryImage = async () => {
    try {
      const permissionResult =
        await ImagePicker.requestMediaLibraryPermissionsAsync();
      if (!permissionResult.granted) {
        Alert.alert("Permission Required", "Permission to access camera roll is required.");
        return;
      }
      const result = await ImagePicker.launchImageLibraryAsync({
        mediaTypes: ImagePicker.MediaTypeOptions.Images,
        quality: 0.8,
      });
      if (!result.canceled && result.assets[0]) {
        setBoundaryImage(result.assets[0].uri);
      }
    } catch (_) {
      Alert.alert("Error", "Failed to pick image");
    }
  };

  const handleRemoveBoundaryImage = () => {
    setBoundaryImage(null);
    setBoundaryRegionCount(0);
    setCanvasRerenderKey((prev) => prev + 1);
  };

  const handleBoundaryImageLoad = (event: NativeEvent<BoundaryImageLoadEvent>) => {
    const { success, regionCount, error } = event.nativeEvent;
    if (success && regionCount) {
      setBoundaryRegionCount(regionCount);
    } else if (!success) {
      Alert.alert("Error", error ?? "Failed to load boundary image");
    }
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

  const handleLoadCanvasData = async () => {
    if (pencilKitRef.current && savedCanvasData) {
      try {
        const ok = await pencilKitRef.current.setCanvasDataFromBase64(
          savedCanvasData
        );
        if (ok) {
          Alert.alert("Loaded", "Canvas data restored from saved data.");
        } else {
          Alert.alert("Error", "Failed to load canvas data");
        }
      } catch (_) {
        Alert.alert("Error", "Failed to load canvas data");
      }
    } else if (!savedCanvasData) {
      Alert.alert("No data", "Save canvas data first, then load.");
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

  const handleSaveImageWithDrawing = async () => {
    if (pencilKitRef.current) {
      try {
        const base64Image = await pencilKitRef.current.captureImageWithDrawing();
        await Share.share({
          title: "PencilKit Image + Drawing",
          message: "Check out my image with drawing!",
          url: `data:image/png;base64,${base64Image}`,
        });
        Alert.alert(
          "Saved",
          `Image with drawing saved (${Math.round(base64Image.length / 1024)} KB)`
        );
      } catch (_) {
        Alert.alert("Error", "Failed to save image with drawing");
      }
    }
  };

  return (
    <SafeAreaView style={styles.container}>
      <StatusBar barStyle={isDark ? "light-content" : "dark-content"} />
      {/* Canvas — a single stable PencilKitView. The container morphs between framed
          and full-screen; the view is never remounted, so coloring progress, the
          configured tool, and the page transform all survive the toggle. */}
      <View style={isFullScreen ? styles.canvasFullScreen : styles.canvasSection}>
        <View style={isFullScreen ? styles.canvasFrameFull : styles.canvasFrame}>
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
                <TouchableOpacity
                  style={[
                    styles.toolButton,
                    !canUndoState && styles.toolButtonDisabled,
                  ]}
                  onPress={handleUndo}
                  disabled={!canUndoState}
                  hitSlop={HIT_SLOP}
                >
                  <FontAwesome5 name="undo" size={14} color={c.surface} />
                </TouchableOpacity>
                <TouchableOpacity
                  style={[
                    styles.toolButton,
                    !canRedoState && styles.toolButtonDisabled,
                  ]}
                  onPress={handleRedo}
                  disabled={!canRedoState}
                  hitSlop={HIT_SLOP}
                >
                  <FontAwesome5 name="redo" size={14} color={c.surface} />
                </TouchableOpacity>
                <TouchableOpacity
                  style={styles.toolButton}
                  onPress={handleShowColorPicker}
                  hitSlop={HIT_SLOP}
                >
                  <FontAwesome5 name="palette" size={14} color={c.surface} />
                </TouchableOpacity>
                <TouchableOpacity
                  style={styles.toolButton}
                  onPress={handleClear}
                  hitSlop={HIT_SLOP}
                >
                  <MaterialCommunityIcons
                    name="eraser"
                    size={14}
                    color={c.surface}
                  />
                </TouchableOpacity>
                <TouchableOpacity
                  style={styles.toolButton}
                  onPress={handleToggleFullScreen}
                  hitSlop={HIT_SLOP}
                >
                  <MaterialCommunityIcons
                    name={isFullScreen ? "fullscreen-exit" : "fullscreen"}
                    size={16}
                    color={c.surface}
                  />
                </TouchableOpacity>
              </View>
            </View>
            <View style={isFullScreen ? styles.canvasWrapperFull : styles.canvasWrapper}>
              <PencilKitView
                key={canvasRerenderKey.toString()}
                ref={pencilKitRef}
                style={isFullScreen ? styles.canvasFull : styles.canvas}
                imagePath={
                  backgroundImage ? { uri: backgroundImage } : undefined
                }
                boundaryImagePath={
                  boundaryImage ? { uri: boundaryImage } : undefined
                }
                boundaryColoringEnabled={boundaryColoringEnabled}
                boundaryDebug={boundaryDebug}
                pageTransformEnabled
                onDrawStart={handleDrawStart}
                onDrawEnd={handleDrawEnd}
                onDrawChange={handleDrawChange}
                onCanUndoChanged={handleCanUndoChanged}
                onCanRedoChanged={handleCanRedoChanged}
                onBoundaryImageLoad={handleBoundaryImageLoad}
              />
            </View>
        </View>
      </View>

      {!isFullScreen && (
        <ScrollView
          style={styles.scrollView}
          contentContainerStyle={styles.scrollContent}
          showsVerticalScrollIndicator={false}
        >
          <View style={styles.header}>
            <Text style={styles.title}>PencilKit</Text>
            <Text style={styles.subtitle}>Draw & color on the canvas above</Text>
          </View>

        {/* Coloring book */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Coloring book</Text>

          <Text style={styles.label}>Boundary image</Text>
          {boundaryImage ? (
            <View style={styles.imageRow}>
              <Image
                source={{ uri: boundaryImage }}
                style={styles.thumb}
                resizeMode="cover"
              />
              <Pressable
                style={styles.removeImageButton}
                onPress={handleRemoveBoundaryImage}
              >
                <FontAwesome5 name="times" size={12} color={c.danger} />
                <Text style={styles.removeImageText}>Remove</Text>
              </Pressable>
            </View>
          ) : (
            <Pressable style={styles.outlineButton} onPress={handlePickBoundaryImage}>
              <FontAwesome5 name="image" size={16} color={c.accent} />
              <Text style={styles.outlineButtonText}>Pick coloring page</Text>
            </Pressable>
          )}

          {boundaryImage ? (
            <>
              <View style={[styles.switchRow, styles.labelSpaced]}>
                <Text style={styles.switchLabel}>Boundary clipping</Text>
                <Switch
                  value={boundaryColoringEnabled}
                  onValueChange={setBoundaryColoringEnabled}
                  trackColor={{ true: c.accent }}
                />
              </View>
              <View style={styles.switchRow}>
                <Text style={styles.switchLabel}>Debug overlay</Text>
                <Switch
                  value={boundaryDebug}
                  onValueChange={setBoundaryDebug}
                  trackColor={{ true: c.success }}
                />
              </View>
              {boundaryRegionCount > 0 ? (
                <Text style={styles.hint}>
                  {boundaryRegionCount} colorable regions detected
                </Text>
              ) : null}
            </>
          ) : null}
        </View>

        {/* Export & share */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Export & share</Text>
          <View style={styles.row}>
            <Pressable
              style={styles.primaryButton}
              onPress={handleSaveCanvasData}
            >
              <FontAwesome5 name="save" size={16} color={c.surface} />
              <Text style={styles.primaryButtonText}>Save data</Text>
            </Pressable>
            <Pressable
              style={[
                styles.primaryButton,
                !savedCanvasData && styles.toolButtonDisabled,
              ]}
              onPress={handleLoadCanvasData}
              disabled={!savedCanvasData}
            >
              <FontAwesome5 name="folder-open" size={16} color={c.surface} />
              <Text style={styles.primaryButtonText}>Load data</Text>
            </Pressable>
          </View>
          <View style={[styles.row, styles.rowSpaced]}>
            <Pressable style={styles.primaryButton} onPress={handleExportImage}>
              <FontAwesome5 name="share-alt" size={16} color={c.surface} />
              <Text style={styles.primaryButtonText}>Share image</Text>
            </Pressable>
          </View>
          <View style={[styles.row, styles.rowSpaced]}>
            <Pressable
              style={styles.primaryButton}
              onPress={handleSaveImageWithDrawing}
            >
              <FontAwesome5 name="image" size={16} color={c.surface} />
              <Text style={styles.primaryButtonText}>Save image & drawing</Text>
            </Pressable>
          </View>
          {savedCanvasData ? (
            <Text style={styles.hint}>
              Saved data: {Math.round(savedCanvasData.length / 1024)} KB — tap
              "Load data" to restore strokes
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
                <FontAwesome5 name="times" size={12} color={c.danger} />
                <Text style={styles.removeImageText}>Remove</Text>
              </Pressable>
            </View>
          ) : (
            <Pressable style={styles.outlineButton} onPress={handlePickImage}>
              <FontAwesome5 name="image" size={16} color={c.accent} />
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
              placeholderTextColor={c.inkMuted}
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
      )}
    </SafeAreaView>
  );
}

const createStyles = (c: Palette) =>
  StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: c.paper,
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
    color: c.ink,
    letterSpacing: -0.5,
  },
  subtitle: {
    fontSize: 15,
    color: c.inkMuted,
    marginTop: 4,
  },
  canvasSection: {
    alignItems: "center",
    marginBottom: 24,
  },
  canvasFrame: {
    width: CANVAS_SIZE + 2,
    borderRadius: 16,
    backgroundColor: c.surface,
    borderWidth: 1,
    borderColor: c.border,
    overflow: "hidden",
    shadowColor: c.ink,
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
    backgroundColor: c.paperDark,
    borderBottomWidth: 1,
    borderBottomColor: c.border,
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
    backgroundColor: c.inkMuted,
  },
  statusDotActive: {
    backgroundColor: c.success,
  },
  statusLabel: {
    fontSize: 13,
    color: c.inkMuted,
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
    backgroundColor: c.accent,
    justifyContent: "center",
    alignItems: "center",
  },
  toolButtonDisabled: {
    backgroundColor: c.inkMuted,
    opacity: 0.7,
  },
  canvasWrapper: {
    overflow: "hidden",
    borderRadius: 0,
  },
  canvas: {
    width: CANVAS_SIZE,
    height: CANVAS_SIZE,
    backgroundColor: c.surface,
  },
  section: {
    backgroundColor: c.surface,
    borderRadius: 14,
    padding: 18,
    marginBottom: 12,
    borderWidth: 1,
    borderColor: c.border,
  },
  sectionTitle: {
    fontSize: 17,
    fontWeight: "600",
    color: c.ink,
    marginBottom: 14,
  },
  label: {
    fontSize: 14,
    fontWeight: "500",
    color: c.inkMuted,
    marginBottom: 8,
  },
  labelSpaced: {
    marginTop: 16,
  },
  row: {
    flexDirection: "row",
    gap: 10,
  },
  rowSpaced: {
    marginTop: 10,
  },
  primaryButton: {
    flex: 1,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    height: 48,
    borderRadius: 12,
    backgroundColor: c.accent,
  },
  primaryButtonText: {
    fontSize: 15,
    fontWeight: "600",
    color: c.surface,
  },
  outlineButton: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    height: 44,
    borderRadius: 10,
    borderWidth: 1.5,
    borderColor: c.accent,
    backgroundColor: "transparent",
  },
  outlineButtonText: {
    fontSize: 15,
    fontWeight: "500",
    color: c.accent,
  },
  hint: {
    fontSize: 13,
    color: c.inkMuted,
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
    backgroundColor: c.paperDark,
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
    color: c.danger,
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
    borderColor: c.border,
  },
  colorInput: {
    flex: 1,
    height: 44,
    borderWidth: 1,
    borderColor: c.border,
    borderRadius: 10,
    paddingHorizontal: 12,
    fontSize: 15,
    fontFamily: "monospace",
    color: c.ink,
  },
  smallButton: {
    paddingHorizontal: 14,
    height: 44,
    borderRadius: 10,
    backgroundColor: c.accent,
    justifyContent: "center",
    alignItems: "center",
  },
  smallButtonSecondary: {
    backgroundColor: "transparent",
    borderWidth: 1,
    borderColor: c.border,
  },
  smallButtonText: {
    fontSize: 14,
    fontWeight: "600",
    color: c.surface,
  },
  smallButtonTextSecondary: {
    fontSize: 14,
    fontWeight: "500",
    color: c.inkMuted,
  },
  switchRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 8,
  },
  switchLabel: {
    fontSize: 15,
    color: c.ink,
  },
  footer: {
    height: 24,
  },
  // Full-screen variants of the canvas container. The framed styles above and these
  // toggle on the SAME elements, so the PencilKitView is restyled, never remounted.
  canvasFullScreen: {
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    zIndex: 10,
    backgroundColor: c.ink,
    paddingTop: 50, // clear the status bar / notch so the toolbar is reachable
  },
  canvasFrameFull: {
    flex: 1,
    backgroundColor: c.surface,
    overflow: "hidden",
  },
  canvasWrapperFull: {
    flex: 1,
    overflow: "hidden",
  },
  canvasFull: {
    flex: 1,
    backgroundColor: c.surface,
  },
});

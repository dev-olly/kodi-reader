import { NativeTabs } from 'expo-router/unstable-native-tabs';

import { usePalette } from '@/hooks/use-palette';

export default function TabLayout() {
  const palette = usePalette();
  return (
    <NativeTabs minimizeBehavior="onScrollDown" tintColor={palette.accent} backgroundColor={palette.page}>
      <NativeTabs.Trigger name="library">
        <NativeTabs.Trigger.Icon sf={{ default: 'books.vertical', selected: 'books.vertical.fill' }} md="menu_book" />
        <NativeTabs.Trigger.Label>Library</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="notes">
        <NativeTabs.Trigger.Icon sf={{ default: 'highlighter', selected: 'highlighter' }} md="edit_note" />
        <NativeTabs.Trigger.Label>Notes</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="settings">
        <NativeTabs.Trigger.Icon sf={{ default: 'gearshape', selected: 'gearshape.fill' }} md="settings" />
        <NativeTabs.Trigger.Label>Settings</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
    </NativeTabs>
  );
}

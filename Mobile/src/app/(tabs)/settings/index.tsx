import { Button, Form, Host, LabeledContent, Link, Section, Text } from '@expo/ui/swift-ui';
import { foregroundStyle, scrollContentBackground, tint } from '@expo/ui/swift-ui/modifiers';
import Constants from 'expo-constants';
import * as Haptics from 'expo-haptics';
import { Stack } from 'expo-router';
import { useCallback, useState } from 'react';
import { Alert, StyleSheet } from 'react-native';

import { AppearanceSections } from '@/components/AppearanceForm';
import { usePalette } from '@/hooks/use-palette';
import { addSampleBooks } from '@/lib/samples';
import { useRecents } from '@/lib/store';

export default function SettingsScreen() {
  const palette = usePalette();
  const books = useRecents();
  const [busy, setBusy] = useState(false);
  const notes = books.reduce((sum, book) => sum + book.annotations.length, 0);

  const addSamples = useCallback(async () => {
    try {
      setBusy(true);
      const added = await addSampleBooks();
      await Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      Alert.alert(added > 0 ? 'Added' : 'Already here', added > 0 ? `${added} sample ${added === 1 ? 'book' : 'books'} added to your library.` : 'The sample books are already in your library.');
    } catch (error) {
      Alert.alert('Could not add samples', error instanceof Error ? error.message : String(error));
    } finally {
      setBusy(false);
    }
  }, []);

  const version = Constants.expoConfig?.version ?? '0.1.0';

  return (
    <>
      <Stack.Screen options={{ title: 'Settings' }} />
      <Host style={[styles.host, { backgroundColor: palette.page }]} colorScheme={palette.isDark ? 'dark' : 'light'}>
        <Form modifiers={[tint(palette.accent), scrollContentBackground('hidden')]}>
          <AppearanceSections />
          <Section title="Library">
            <LabeledContent label="Books">
              <Text>{String(books.length)}</Text>
            </LabeledContent>
            <LabeledContent label="Notes">
              <Text>{String(notes)}</Text>
            </LabeledContent>
            <Button label={busy ? 'Adding…' : 'Add Sample Books'} systemImage="books.vertical" onPress={addSamples} />
          </Section>
          <Section title="Privacy" footer={<Text modifiers={[foregroundStyle({ type: 'hierarchical', style: 'secondary' })]}>Books, highlights and notes stay on this device. There is no analytics or telemetry.</Text>}>
            <Text>Everything is stored locally</Text>
          </Section>
          <Section title="About">
            <LabeledContent label="Kodi Reader">
              <Text>{version}</Text>
            </LabeledContent>
            <Link destination="https://www.kodi-reader.app/">
              <Text>Kodi Reader for Mac</Text>
            </Link>
            <Link destination="https://github.com/dev-olly/kodi-reader">
              <Text>Source on GitHub</Text>
            </Link>
          </Section>
        </Form>
      </Host>
    </>
  );
}

const styles = StyleSheet.create({
  host: { flex: 1 },
});

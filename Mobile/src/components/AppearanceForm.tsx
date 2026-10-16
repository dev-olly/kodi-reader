import { HStack, Picker, Section, Slider, Spacer, Text, Toggle, VStack } from '@expo/ui/swift-ui';
import { font, foregroundStyle, monospacedDigit, pickerStyle, tag } from '@expo/ui/swift-ui/modifiers';

import { updateSettings, useSettings } from '@/lib/store';
import { FONT_LABELS, SETTINGS_RANGES, type ReaderFont, type ReaderTheme } from '@/lib/types';

const FONTS = Object.keys(FONT_LABELS) as ReaderFont[];

function SliderRow({ title, value, display, range, onChange }: {
  title: string;
  value: number;
  display: string;
  range: { min: number; max: number; step: number };
  onChange: (value: number) => void;
}) {
  return (
    <VStack alignment="leading" spacing={6}>
      <HStack>
        <Text>{title}</Text>
        <Spacer />
        <Text modifiers={[foregroundStyle({ type: 'hierarchical', style: 'secondary' }), monospacedDigit()]}>{display}</Text>
      </HStack>
      <Slider value={value} min={range.min} max={range.max} step={range.step} onValueChange={onChange} />
    </VStack>
  );
}

/**
 * Native SwiftUI appearance controls, used by the typography sheet in the
 * reader and by the Settings tab. Every change flows straight through to the
 * open book, which repaginates around the current position.
 */
export function AppearanceSections() {
  const settings = useSettings();
  return (
    <>
      <Section title="Theme">
        <Picker
          selection={settings.theme}
          onSelectionChange={(theme) => updateSettings({ theme: theme as ReaderTheme })}
          modifiers={[pickerStyle('segmented')]}>
          <Text modifiers={[tag('light')]}>Light</Text>
          <Text modifiers={[tag('dark')]}>Dark</Text>
          <Text modifiers={[tag('system')]}>System</Text>
        </Picker>
      </Section>
      <Section title="Typography">
        <Picker
          label="Font"
          selection={settings.font}
          onSelectionChange={(value) => updateSettings({ font: value as ReaderFont })}
          modifiers={[pickerStyle('menu')]}>
          {FONTS.map((name) => (
            <Text key={name} modifiers={[tag(name), font({ design: name === 'system' || name === 'sansSerif' ? 'default' : 'serif' })]}>
              {FONT_LABELS[name]}
            </Text>
          ))}
        </Picker>
        <SliderRow
          title="Text Size"
          value={settings.fontSize}
          display={`${Math.round(settings.fontSize)} pt`}
          range={SETTINGS_RANGES.fontSize}
          onChange={(value) => updateSettings({ fontSize: Math.round(value) })}
        />
        <SliderRow
          title="Line Spacing"
          value={settings.lineHeight}
          display={settings.lineHeight.toFixed(1)}
          range={SETTINGS_RANGES.lineHeight}
          onChange={(value) => updateSettings({ lineHeight: Math.round(value * 10) / 10 })}
        />
        <SliderRow
          title="Margins"
          value={settings.marginRatio}
          display={`${Math.round(settings.marginRatio * 100)}%`}
          range={SETTINGS_RANGES.marginRatio}
          onChange={(value) => updateSettings({ marginRatio: Math.round(value * 100) / 100 })}
        />
      </Section>
      <Section title="Layout">
        <Toggle label="Justify Text" isOn={settings.justified} onIsOnChange={(justified) => updateSettings({ justified })} />
        <Toggle label="Hyphenation" isOn={settings.hyphenated} onIsOnChange={(hyphenated) => updateSettings({ hyphenated })} />
        <Toggle
          label="Animate Page Turns"
          isOn={settings.animatePageTurns}
          onIsOnChange={(animatePageTurns) => updateSettings({ animatePageTurns })}
        />
      </Section>
    </>
  );
}

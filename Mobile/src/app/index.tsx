import { Redirect } from 'expo-router';

/** The app opens on the Library tab. */
export default function Index() {
  return <Redirect href="/library" />;
}

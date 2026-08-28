import { Platform } from 'react-native'
import { Navigation } from 'react-native-navigation'

let launched = false
let listening = false
let launchFallbackTimer: ReturnType<typeof setTimeout> | null = null
const handlers: Array<() => void> = []

const notifyLaunched = () => {
  if (launched) return
  launched = true

  if (launchFallbackTimer != null) {
    clearTimeout(launchFallbackTimer)
    launchFallbackTimer = null
  }

  setImmediate(() => {
    for (const handler of [...handlers]) handler()
  })
}

export const listenLaunchEvent = () => {
  if (listening) return
  listening = true

  Navigation.events().registerAppLaunchedListener(() => {
    notifyLaunched()
  })

  // ReactNativeNavigation can emit the native app-launched notification before
  // the JS listener is registered on a cold iOS/TrollStore launch. In that case
  // the old code waited forever and no root screen was ever installed, leaving
  // a completely black phone window. Android keeps the original event-only path.
  if (Platform.OS === 'ios') {
    launchFallbackTimer = setTimeout(() => {
      console.warn('[iOS bootstrap] AppLaunched event was not observed; using safe fallback.')
      notifyLaunched()
    }, 1500)
  }
}

export const onAppLaunched = (handler: () => void) => {
  handlers.push(handler)
  if (launched) {
    setImmediate(() => {
      handler()
    })
  }
}

import { ActivityIndicator, StyleSheet, Text, View } from 'react-native'
import { Navigation } from 'react-native-navigation'
import { BOOT_SCREEN } from './screenNames'

let registered = false

const BootstrapScreen = () => (
  <View style={styles.container}>
    <ActivityIndicator size="large" />
    <Text style={styles.title}>LX Music</Text>
    <Text style={styles.message}>正在启动播放器…</Text>
  </View>
)

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#ffffff',
    paddingHorizontal: 32,
  },
  title: {
    marginTop: 20,
    color: '#111111',
    fontSize: 22,
    fontWeight: '600',
  },
  message: {
    marginTop: 10,
    color: '#666666',
    fontSize: 14,
    textAlign: 'center',
  },
})

export const registerBootstrapScreen = () => {
  if (registered) return
  registered = true
  Navigation.registerComponent(BOOT_SCREEN, () => BootstrapScreen)
}

export const showBootstrapScreen = async() => Navigation.setRoot({
  root: {
    component: {
      name: BOOT_SCREEN,
      options: {
        topBar: {
          visible: false,
        },
        statusBar: {
          drawBehind: false,
          visible: true,
          style: 'dark',
          backgroundColor: '#ffffff',
        },
        layout: {
          componentBackgroundColor: '#ffffff',
        },
      },
    },
  },
})

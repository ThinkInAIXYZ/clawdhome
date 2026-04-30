import i18n from "i18next"
import { initReactI18next } from "react-i18next"
import en from "./en.json"
import zh from "./zh.json"

i18n.use(initReactI18next).init({
  resources: {
    en: { translation: en },
    zh: { translation: zh },
  },
  // 默认中文；若中文缺失键再回退英文
  lng: "zh",
  fallbackLng: ["zh", "en"],
  interpolation: { escapeValue: false },
})

export default i18n

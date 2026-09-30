-- Strings: every text this QuickApp shows in the HC3 user interface.
-- English is the default. FR and IT are not reviewed by a native speaker;
-- corrections are welcome.

Strings = {
  ["ui.refresh"] = {
    en = "Refresh",
    de = "Aktualisieren",
    fr = "Actualiser",
    it = "Aggiorna",
  },
  ["status.loggingIn"] = {
    en = "Logging in to the inverter (takes about 20 s)…",
    de = "Anmeldung am Wechselrichter (dauert etwa 20 s)…",
    fr = "Connexion à l’onduleur (environ 20 s)…",
    it = "Accesso all’inverter (circa 20 s)…",
  },
  ["status.online"] = {
    en = "PV {pv} W · battery {soc} % · {time}",
    de = "PV {pv} W · Batterie {soc} % · {time}",
    fr = "PV {pv} W · batterie {soc} % · {time}",
    it = "FV {pv} W · batteria {soc} % · {time}",
  },
  ["status.unreachable"] = {
    en = "Inverter not reachable – next attempt in {seconds} s",
    de = "Wechselrichter nicht erreichbar – neuer Versuch in {seconds} s",
    fr = "Onduleur injoignable – nouvel essai dans {seconds} s",
    it = "Inverter non raggiungibile – nuovo tentativo tra {seconds} s",
  },
  ["status.authFailed"] = {
    en = "Login rejected – please check the password",
    de = "Anmeldung abgelehnt – bitte Passwort prüfen",
    fr = "Connexion refusée – veuillez vérifier le mot de passe",
    it = "Accesso rifiutato – verificare la password",
  },
  ["status.protocolError"] = {
    en = "Unexpected answer from the inverter – see the log",
    de = "Unerwartete Antwort des Wechselrichters – Details im Log",
    fr = "Réponse inattendue de l’onduleur – voir le journal",
    it = "Risposta inattesa dall’inverter – vedere il registro",
  },
}

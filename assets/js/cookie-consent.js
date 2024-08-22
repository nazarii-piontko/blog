window.cookieconsent.initialise({
  "palette": {
    "popup": {
    "background": "#000"
    },
    "button": {
    "background": "#f1d600"
    }
  },
  "type": "opt-in",
  "content": {
    "message": "We use cookies to analyze site traffic and optimize your browsing experience."
  },
  onInitialise: function (status) {
    var type = this.options.type;
    var didConsent = this.hasConsented();
    if (type == 'opt-in' && didConsent)
    setCookiesHasConsent();
    else if (type == 'opt-out' && !didConsent)
    setCookiesHasNotConsent();
  },
  onStatusChange: function(status, chosenBefore) {
    var type = this.options.type;
    var didConsent = this.hasConsented();
    if (type == 'opt-in' && didConsent)
    setCookiesHasConsent();
    else if (type == 'opt-out' && !didConsent)
    setCookiesHasNotConsent();
  },
  onRevokeChoice: function() {
    var type = this.options.type;
    if (type == 'opt-in')
    setCookiesHasNotConsent();
    else if (type == 'opt-out')
    setCookiesHasConsent();
  }
});

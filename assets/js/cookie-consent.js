window.cookieconsent.initialise({
  "palette": {
    "popup": {
      "background": "#0f1115"
    }
  },
  "type": "opt-in",
  "position": "top-right",
  "revokable": false,
  "animateRevokable": true,
  "content": {
    "message": "This website uses cookies to analyze site traffic and improve your browsing experience."
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

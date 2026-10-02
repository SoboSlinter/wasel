import { renderChrome, params, safeNext } from "./app.js";
import { mountProviderForm } from "./provider-form.js";

// One page for becoming a provider: account, business, areas, documents and agreement.
// Someone who is already signed in goes to the provider page, which shows the same form without the account step.
const user = await renderChrome();
if (user) {
  const next = params().get("next");
  location.replace(next ? safeNext(next) : "provider.html");
} else {
  mountProviderForm(document.getElementById("provider"), { user: null, afterDone: () => location.assign("provider.html") });
}

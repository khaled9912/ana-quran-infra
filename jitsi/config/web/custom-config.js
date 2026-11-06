// Keep the room UI in English regardless of the viewer's browser locale.
config.defaultLanguage = 'en';

// Branding is served from this deployment so the virtual background image is
// same-origin and does not need CORS headers.
config.dynamicBrandingUrl = '/branding/ana-quran-branding.json';

// Offer only the branded image; participants cannot add their own backgrounds.
config.virtualBackground = {
    ...(config.virtualBackground || {}),
    disableAddingImages: true,
};

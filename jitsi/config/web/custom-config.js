// Keep the room UI in English regardless of the viewer's browser locale.
config.defaultLanguage = 'en';

// The academy backdrop is a switch, not a default: it reaches a room only when
// the API reports LessonRoom__CameraBackground as on, which is when both clients
// stop disabling virtual backgrounds. This file puts the single branded picture
// in their picker.
config.dynamicBrandingUrl = '/branding/ana-quran-branding.json';

// Served from this deployment, so the image is same-origin with the room and
// needs no CORS headers; participants cannot add backgrounds of their own.
config.virtualBackground = {
    ...(config.virtualBackground || {}),
    disableAddingImages: true,
};

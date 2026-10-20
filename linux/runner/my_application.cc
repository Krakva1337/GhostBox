#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

static FlMethodChannel* app_icon_channel = nullptr;

static void update_desktop_icon(const gchar* icon_name) {
  gchar* desktop_file = g_build_filename(g_get_user_data_dir(), "applications",
                                         "ghostbox.desktop", nullptr);
  gchar* contents = nullptr;
  gsize length = 0;
  if (g_file_get_contents(desktop_file, &contents, &length, nullptr)) {
    gchar** lines = g_strsplit(contents, "\n", -1);
    for (guint i = 0; lines[i] != nullptr; i++) {
      if (g_str_has_prefix(lines[i], "Icon=")) {
        g_free(lines[i]);
        lines[i] = g_strdup_printf("Icon=%s", icon_name);
        break;
      }
    }
    gchar* updated = g_strjoinv("\n", lines);
    g_file_set_contents(desktop_file, updated, -1, nullptr);
    g_free(updated);
    g_strfreev(lines);
    g_free(contents);
  }
  g_free(desktop_file);
}

static void set_app_icon(FlMethodChannel* channel, FlMethodCall* call,
                         gpointer user_data) {
  (void)channel;
  gboolean changed = FALSE;
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  FlValue* variant_value = fl_value_lookup_string(args, "variant");
  const gchar* variant = variant_value != nullptr &&
                                 fl_value_get_type(variant_value) == FL_VALUE_TYPE_STRING
                             ? fl_value_get_string(variant_value)
                             : nullptr;
  if (g_strcmp0(method, "setAppIcon") == 0 &&
      g_strcmp0(variant, "custom") == 0) {
    FlValue* png_value = fl_value_lookup_string(args, "customPng");
    if (png_value != nullptr &&
        fl_value_get_type(png_value) == FL_VALUE_TYPE_UINT8_LIST) {
      const guint8* png = fl_value_get_uint8_list(png_value);
      const gsize length = fl_value_get_length(png_value);
      GdkPixbufLoader* loader = gdk_pixbuf_loader_new();
      g_autoptr(GError) decode_error = nullptr;
      const gboolean wrote = gdk_pixbuf_loader_write(loader, png, length,
                                                     &decode_error);
      const gboolean closed = wrote &&
          gdk_pixbuf_loader_close(loader, &decode_error);
      GdkPixbuf* pixbuf = gdk_pixbuf_loader_get_pixbuf(loader);
      if (closed && pixbuf != nullptr) {
        gtk_window_set_icon(GTK_WINDOW(user_data), pixbuf);
        changed = TRUE;
        gchar* icon_dir = g_build_filename(g_get_user_data_dir(), "icons",
                                           "hicolor", "512x512", "apps",
                                           nullptr);
        g_mkdir_with_parents(icon_dir, 0755);
        gchar* icon_path = g_build_filename(icon_dir, "ghostbox-custom.png", nullptr);
        const gboolean stored = g_file_set_contents(
            icon_path, reinterpret_cast<const gchar*>(png), length, nullptr);
        if (stored) update_desktop_icon(icon_path);
        g_free(icon_path);
        g_free(icon_dir);
      }
      g_object_unref(loader);
    }
  } else if (g_strcmp0(method, "setAppIcon") == 0 && variant != nullptr) {
    gboolean safe_variant = *variant != '\0';
    for (const gchar* cursor = variant; *cursor != '\0'; cursor++) {
      safe_variant = safe_variant && g_ascii_islower(*cursor);
    }
    if (!safe_variant) {
      g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
      fl_method_call_respond_success(call, result, nullptr);
      return;
    }
    gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
    if (executable != nullptr) {
      gchar* directory = g_path_get_dirname(executable);
      gchar* filename = g_strdup_printf("%s.png", variant);
      gchar* icon_path = g_build_filename(directory, "data", "flutter_assets",
                                          "assets", "icons", filename, nullptr);
      g_autoptr(GError) icon_error = nullptr;
      changed = gtk_window_set_icon_from_file(GTK_WINDOW(user_data), icon_path,
                                               &icon_error);
      gchar* svg_name = g_strdup_printf("%s.svg", variant);
      gchar* svg_path = g_build_filename(directory, "data", "flutter_assets",
                                         "assets", "icons", svg_name, nullptr);
      gchar* svg_contents = nullptr;
      gsize svg_length = 0;
      if (g_file_get_contents(svg_path, &svg_contents, &svg_length, nullptr)) {
        gchar* installed_icon = g_build_filename(g_get_user_data_dir(), "icons",
            "hicolor", "scalable", "apps", "ghostbox.svg", nullptr);
        gchar* installed_dir = g_path_get_dirname(installed_icon);
        g_mkdir_with_parents(installed_dir, 0755);
        if (g_file_set_contents(installed_icon, svg_contents, svg_length, nullptr))
          update_desktop_icon(installed_icon);
        g_free(installed_icon);
        g_free(installed_dir);
        g_free(svg_contents);
      }
      g_free(svg_path);
      g_free(svg_name);
      g_free(icon_path);
      g_free(filename);
      g_free(directory);
      g_free(executable);
    }
  }
  g_autoptr(FlValue) result = fl_value_new_bool(changed);
  fl_method_call_respond_success(call, result, nullptr);
}

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  const gchar* icon_path = g_getenv("GHOSTBOX_ICON_PATH");
  if (icon_path != nullptr && g_file_test(icon_path, G_FILE_TEST_IS_REGULAR)) {
    g_autoptr(GError) icon_error = nullptr;
    if (!gtk_window_set_icon_from_file(window, icon_path, &icon_error)) {
      g_warning("Could not load GhostBox window icon: %s",
                icon_error->message);
    }
  }

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "GhostBox");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "GhostBox");
  }

  gtk_window_set_default_size(window, 393, 852);
  gtk_window_set_resizable(window, FALSE);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  g_autoptr(FlStandardMethodCodec) icon_codec = fl_standard_method_codec_new();
  g_set_object(&app_icon_channel,
               fl_method_channel_new(
                   fl_engine_get_binary_messenger(fl_view_get_engine(view)),
                   "app.ghostbox.ghostbox/app_icon",
                   FL_METHOD_CODEC(icon_codec)));
  fl_method_channel_set_method_call_handler(
      app_icon_channel, set_app_icon, g_object_ref(window), g_object_unref);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  // Let GApplication forward the original URI arguments to an already
  // running instance. The app_links GTK plugin handles the command-line/open
  // signals in Dart.
  return FALSE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     static_cast<GApplicationFlags>(
                                         G_APPLICATION_HANDLES_COMMAND_LINE |
                                         G_APPLICATION_HANDLES_OPEN),
                                     nullptr));
}

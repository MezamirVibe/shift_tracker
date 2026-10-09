package com.example.quickchatwidget;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.Context;
import android.content.Intent;
import android.widget.RemoteViews;

public class QuickWidgetProvider extends AppWidgetProvider {
    @Override
    public void onUpdate(Context context, AppWidgetManager manager, int[] appWidgetIds) {
        for (int id : appWidgetIds) {
            RemoteViews views = new RemoteViews(context.getPackageName(), R.layout.widget_quick_note);

            Intent composeIntent = new Intent(context, ComposerActivity.class);
            PendingIntent composePending = PendingIntent.getActivity(
                    context,
                    1001,
                    composeIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
            );
            views.setOnClickPendingIntent(R.id.widget_main, composePending);

            Intent settingsIntent = new Intent(context, SettingsActivity.class);
            PendingIntent settingsPending = PendingIntent.getActivity(
                    context,
                    1002,
                    settingsIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
            );
            views.setOnClickPendingIntent(R.id.widget_settings, settingsPending);

            manager.updateAppWidget(id, views);
        }
    }
}

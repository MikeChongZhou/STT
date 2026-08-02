package com.timbertrail.screentimeguardian

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

data class UiTableColumn(
    val title: String,
    val widthDp: Int,
    val gravity: Int = Gravity.START or Gravity.CENTER_VERTICAL
)

data class UiActionItem(
    val icon: String,
    val title: String,
    val subtitle: String? = null,
    val action: () -> Unit
)

object AppUi {
    const val BACKGROUND_COLOR = 0xFFF2F2F7.toInt()
    private const val surfaceColor = 0xFFFFFFFF.toInt()
    private const val secondarySurfaceColor = 0xFFF7F7FA.toInt()
    private const val headerColor = 0xFFECECF2.toInt()
    private const val separatorColor = 0xFFD7D7DE.toInt()
    private const val textColor = 0xFF111827.toInt()
    private const val secondaryTextColor = 0xFF6B7280.toInt()
    private const val accentColor = 0xFF0A84FF.toInt()
    private const val accentSurfaceColor = 0xFFEAF3FF.toInt()

    fun dp(context: Context, value: Int): Int =
        (value * context.resources.displayMetrics.density).toInt()

    fun page(context: Context, content: LinearLayout): ScrollView =
        ScrollView(context).apply {
            setBackgroundColor(BACKGROUND_COLOR)
            isFillViewport = true
            addView(content)
        }

    fun pageStack(context: Context): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(context, 18), dp(context, 20), dp(context, 18), dp(context, 28))
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }

    fun title(context: Context, value: String): TextView =
        TextView(context).apply {
            text = value
            textSize = 24f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(textColor)
            includeFontPadding = false
            setPadding(0, dp(context, 6), 0, dp(context, 10))
        }

    fun subtitle(context: Context, value: String): TextView =
        TextView(context).apply {
            text = value
            textSize = 13f
            setTextColor(secondaryTextColor)
            setPadding(0, 0, 0, dp(context, 10))
        }

    fun section(context: Context, title: String, child: View): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(context, 8), 0, dp(context, 12))
            addView(TextView(context).apply {
                text = title
                textSize = 13f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(secondaryTextColor)
                setPadding(dp(context, 4), 0, 0, dp(context, 7))
            })
            addView(child)
        }

    fun surface(context: Context): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(context, 16), dp(context, 14), dp(context, 16), dp(context, 14))
            background = rounded(context, surfaceColor, 16, separatorColor, 1)
            elevation = 0f
        }

    fun button(context: Context, title: String, onClick: () -> Unit): Button =
        Button(context).apply {
            text = title
            isAllCaps = false
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(accentColor)
            minHeight = dp(context, 40)
            minWidth = dp(context, 72)
            setPadding(dp(context, 14), 0, dp(context, 14), 0)
            background = rounded(context, accentSurfaceColor, 12, Color.TRANSPARENT, 0)
            setOnClickListener { onClick() }
        }

    fun primaryButton(context: Context, title: String, onClick: () -> Unit): TextView =
        TextView(context).apply {
            text = title
            gravity = Gravity.CENTER
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            includeFontPadding = false
            minHeight = dp(context, 48)
            setPadding(dp(context, 16), dp(context, 14), dp(context, 16), dp(context, 14))
            background = rounded(context, accentColor, 14, Color.TRANSPARENT, 0)
            setOnClickListener { onClick() }
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(context, 2)
                bottomMargin = dp(context, 2)
            }
        }

    fun buttonRow(context: Context, vararg buttons: Button): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.START
            setPadding(0, dp(context, 4), 0, dp(context, 8))
            buttons.forEach { button ->
                button.layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    dp(context, 42)
                ).apply {
                    marginEnd = dp(context, 8)
                }
                addView(button)
            }
        }

    fun heroCard(
        context: Context,
        label: String,
        value: String,
        plan: String,
        progress: Float,
        meta: String
    ): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(context, 16), dp(context, 15), dp(context, 16), dp(context, 15))
            background = rounded(context, surfaceColor, 18, separatorColor, 1)
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(TextView(context).apply {
                        text = label
                        textSize = 13f
                        setTextColor(secondaryTextColor)
                        includeFontPadding = false
                    })
                    addView(TextView(context).apply {
                        text = value
                        textSize = 30f
                        typeface = Typeface.DEFAULT_BOLD
                        setTextColor(textColor)
                        includeFontPadding = false
                        setPadding(0, dp(context, 6), 0, 0)
                    })
                    layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                })
                addView(TextView(context).apply {
                    text = plan
                    textSize = 13f
                    setTextColor(secondaryTextColor)
                    includeFontPadding = false
                    setPadding(dp(context, 10), dp(context, 6), dp(context, 10), dp(context, 6))
                    background = rounded(context, secondarySurfaceColor, 999, separatorColor, 1)
                })
            })
            addView(progressBar(context, progress).apply {
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    dp(context, 9)
                ).apply {
                    topMargin = dp(context, 13)
                    bottomMargin = dp(context, 10)
                }
            })
            addView(TextView(context).apply {
                text = meta
                textSize = 13f
                setTextColor(secondaryTextColor)
            })
        }

    fun actionList(context: Context, items: List<UiActionItem>): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(context, surfaceColor, 18, separatorColor, 1)
            items.forEachIndexed { index, item ->
                addView(actionRow(context, item))
                if (index < items.lastIndex) {
                    addView(View(context).apply {
                        setBackgroundColor(separatorColor)
                        layoutParams = LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            dp(context, 1)
                        ).apply {
                            marginStart = dp(context, 56)
                        }
                    })
                }
            }
        }

    fun summaryCard(context: Context, title: String, rows: List<Pair<String, String>>): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(context, 16), dp(context, 14), dp(context, 16), dp(context, 14))
            background = rounded(context, surfaceColor, 18, separatorColor, 1)
            addView(TextView(context).apply {
                text = title
                textSize = 13f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(secondaryTextColor)
                setPadding(0, 0, 0, dp(context, 4))
            })
            rows.forEach { (label, value) ->
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(0, dp(context, 9), 0, dp(context, 6))
                    addView(TextView(context).apply {
                        text = label
                        textSize = 15f
                        setTextColor(textColor)
                        layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                    })
                    addView(TextView(context).apply {
                        text = value
                        textSize = 15f
                        typeface = Typeface.DEFAULT_BOLD
                        setTextColor(textColor)
                        gravity = Gravity.END
                    })
                })
            }
        }

    fun segmentedControl(
        context: Context,
        options: List<String>,
        selectedIndex: Int,
        onSelected: (Int) -> Unit
    ): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            background = rounded(context, headerColor, 8, separatorColor, 1)
            setPadding(dp(context, 2), dp(context, 2), dp(context, 2), dp(context, 2))
            options.forEachIndexed { index, option ->
                addView(TextView(context).apply {
                    text = option
                    gravity = Gravity.CENTER
                    textSize = 14f
                    typeface = if (index == selectedIndex) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
                    setTextColor(if (index == selectedIndex) textColor else secondaryTextColor)
                    background = if (index == selectedIndex) {
                        rounded(context, surfaceColor, 7, Color.TRANSPARENT, 0)
                    } else {
                        rounded(context, Color.TRANSPARENT, 7, Color.TRANSPARENT, 0)
                    }
                    setPadding(dp(context, 12), dp(context, 8), dp(context, 12), dp(context, 8))
                    setOnClickListener { onSelected(index) }
                    layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                })
            }
        }

    fun table(
        context: Context,
        columns: List<UiTableColumn>,
        rows: List<List<String>>,
        emptyText: String,
        sortColumnIndex: Int? = null,
        sortAscending: Boolean = true,
        onHeaderClick: ((Int) -> Unit)? = null
    ): HorizontalScrollView {
        val tableStack = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
        }
        tableStack.addView(tableRow(
            context = context,
            columns = columns,
            values = columns.mapIndexed { index, column ->
                if (index == sortColumnIndex) {
                    "${column.title} ${if (sortAscending) "▲" else "▼"}"
                } else {
                    column.title
                }
            },
            isHeader = true,
            onHeaderClick = onHeaderClick
        ))
        val visibleRows = rows.ifEmpty {
            listOf(listOf(emptyText) + List(maxOf(0, columns.size - 1)) { "-" })
        }
        visibleRows.forEachIndexed { index, row ->
            tableStack.addView(tableRow(
                context = context,
                columns = columns,
                values = normalizeRow(row, columns.size),
                isHeader = false,
                alternate = index % 2 == 1
            ))
        }

        return HorizontalScrollView(context).apply {
            isHorizontalScrollBarEnabled = true
            overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
            background = rounded(context, surfaceColor, 14, separatorColor, 1)
            elevation = 0f
            addView(tableStack)
        }
    }

    fun keyValueRow(context: Context, label: String, value: String, selectable: Boolean = false): TextView =
        TextView(context).apply {
            text = "$label：$value"
            textSize = 14f
            setTextColor(textColor)
            setPadding(0, dp(context, 6), 0, dp(context, 6))
            setTextIsSelectable(selectable)
        }

    fun fieldLabel(context: Context, value: String): TextView =
        TextView(context).apply {
            text = value
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(secondaryTextColor)
            setPadding(0, dp(context, 10), 0, dp(context, 4))
        }

    fun styleTextField(context: Context, input: TextView): TextView =
        input.apply {
            textSize = 15f
            setTextColor(textColor)
            setPadding(dp(context, 10), 0, dp(context, 10), 0)
            minHeight = dp(context, 42)
            background = rounded(context, secondarySurfaceColor, 12, separatorColor, 1)
        }

    private fun progressBar(context: Context, progress: Float): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            background = rounded(context, secondarySurfaceColor, 999, Color.TRANSPARENT, 0)
            val clamped = progress.coerceIn(0f, 1f)
            addView(View(context).apply {
                background = rounded(context, accentColor, 999, Color.TRANSPARENT, 0)
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, clamped)
            })
            addView(View(context).apply {
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f - clamped)
            })
        }

    private fun actionRow(context: Context, item: UiActionItem): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(context, 14), dp(context, 12), dp(context, 14), dp(context, 12))
            setOnClickListener { item.action() }
            addView(TextView(context).apply {
                text = item.icon
                gravity = Gravity.CENTER
                textSize = 13f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(accentColor)
                background = rounded(context, accentSurfaceColor, 9, Color.TRANSPARENT, 0)
                layoutParams = LinearLayout.LayoutParams(dp(context, 30), dp(context, 30)).apply {
                    marginEnd = dp(context, 12)
                }
            })
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(TextView(context).apply {
                    text = item.title
                    textSize = 16f
                    setTextColor(textColor)
                    includeFontPadding = false
                })
                if (!item.subtitle.isNullOrBlank()) {
                    addView(TextView(context).apply {
                        text = item.subtitle
                        textSize = 12f
                        setTextColor(secondaryTextColor)
                        maxLines = 1
                        ellipsize = TextUtils.TruncateAt.END
                        setPadding(0, dp(context, 4), 0, 0)
                    })
                }
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(TextView(context).apply {
                text = "›"
                textSize = 24f
                setTextColor(secondaryTextColor)
                gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(dp(context, 24), ViewGroup.LayoutParams.WRAP_CONTENT)
            })
        }

    private fun tableRow(
        context: Context,
        columns: List<UiTableColumn>,
        values: List<String>,
        isHeader: Boolean,
        alternate: Boolean = false,
        onHeaderClick: ((Int) -> Unit)? = null
    ): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            columns.forEachIndexed { index, column ->
                addView(TextView(context).apply {
                    text = values.getOrElse(index) { "" }
                    gravity = column.gravity
                    textSize = if (isHeader) 12f else 13f
                    typeface = if (isHeader) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
                    setTextColor(if (isHeader) textColor else textColor)
                    maxLines = if (isHeader) 2 else 2
                    ellipsize = TextUtils.TruncateAt.END
                    setPadding(dp(context, 9), dp(context, 8), dp(context, 9), dp(context, 8))
                    minHeight = dp(context, 40)
                    background = rounded(
                        context = context,
                        fillColor = when {
                            isHeader -> headerColor
                            alternate -> secondarySurfaceColor
                            else -> surfaceColor
                        },
                        radiusDp = 0,
                        strokeColor = separatorColor,
                        strokeDp = 1
                    )
                    if (isHeader && onHeaderClick != null) {
                        setOnClickListener { onHeaderClick(index) }
                    }
                    layoutParams = LinearLayout.LayoutParams(
                        dp(context, column.widthDp),
                        ViewGroup.LayoutParams.WRAP_CONTENT
                    )
                })
            }
        }

    private fun normalizeRow(row: List<String>, size: Int): List<String> =
        when {
            row.size == size -> row
            row.size > size -> row.take(size)
            else -> row + List(size - row.size) { "" }
        }

    private fun rounded(
        context: Context,
        fillColor: Int,
        radiusDp: Int,
        strokeColor: Int,
        strokeDp: Int
    ): GradientDrawable =
        GradientDrawable().apply {
            setColor(fillColor)
            cornerRadius = dp(context, radiusDp).toFloat()
            if (strokeDp > 0) {
                setStroke(dp(context, strokeDp), strokeColor)
            }
        }
}

{CompositeDisposable, Emitter} = require 'event-kit'
{Point, Range} = require 'text-buffer'
_ = require 'underscore-plus'

module.exports =
class TextEditorPresenter
  toggleCursorBlinkHandle: null
  startBlinkingCursorsAfterDelay: null
  stoppedScrollingTimeoutId: null
  mouseWheelScreenRow: null

  constructor: (params) ->
    {@model, @autoHeight, @height, @contentFrameWidth, @scrollTop, @scrollLeft} = params
    {@horizontalScrollbarHeight, @verticalScrollbarWidth} = params
    {@lineHeight, @baseCharacterWidth, @lineOverdrawMargin, @backgroundColor, @gutterBackgroundColor} = params
    {@cursorBlinkPeriod, @cursorBlinkResumeDelay, @stoppedScrollingDelay} = params

    @disposables = new CompositeDisposable
    @emitter = new Emitter
    @charWidthsByScope = {}
    @observeModel()
    @observeConfig()
    @buildState()
    @startBlinkingCursors()

  destroy: ->
    @disposables.dispose()

  onDidUpdateState: (callback) ->
    @emitter.on 'did-update-state', callback

  observeModel: ->
    @disposables.add @model.onDidChange =>
      @updateHeightState()
      @updateVerticalScrollState()
      @updateHorizontalScrollState()
      @updateScrollbarsState()
      @updateContentState()
      @updateDecorations()
      @updateLinesState()
      @updateGutterState()
      @updateLineNumbersState()
    @disposables.add @model.onDidChangeGrammar(@updateContentState.bind(this))
    @disposables.add @model.onDidChangePlaceholderText(@updateContentState.bind(this))
    @disposables.add @model.onDidChangeMini =>
      @updateContentState()
      @updateDecorations()
      @updateLinesState()
      @updateLineNumbersState()
    @disposables.add @model.onDidAddDecoration(@didAddDecoration.bind(this))
    @disposables.add @model.onDidAddCursor(@didAddCursor.bind(this))
    @observeDecoration(decoration) for decoration in @model.getDecorations()
    @observeCursor(cursor) for cursor in @model.getCursors()

  observeConfig: ->
    @disposables.add atom.config.onDidChange 'editor.showIndentGuide', scope: @model.getRootScopeDescriptor(), @updateContentState.bind(this)

  buildState: ->
    @state =
      horizontalScrollbar: {}
      verticalScrollbar: {}
      content:
        scrollingVertically: false
        blinkCursorsOff: false
        lines: {}
        highlights: {}
        overlays: {}
      gutter:
        lineNumbers: {}
    @updateState()

  updateState: ->
    @updateHeightState()
    @updateVerticalScrollState()
    @updateHorizontalScrollState()
    @updateScrollbarsState()
    @updateContentState()
    @updateDecorations()
    @updateLinesState()
    @updateCursorsState()
    @updateOverlaysState()
    @updateGutterState()
    @updateLineNumbersState()

  updateHeightState: ->
    if @autoHeight
      @state.height = @computeContentHeight()
    else
      @state.height = null

    @emitter.emit 'did-update-state'

  updateVerticalScrollState: ->
    scrollHeight = @computeScrollHeight()
    @state.content.scrollHeight = scrollHeight
    @state.gutter.scrollHeight = scrollHeight
    @state.verticalScrollbar.scrollHeight = scrollHeight

    scrollTop = @computeScrollTop()
    @state.content.scrollTop = scrollTop
    @state.gutter.scrollTop = scrollTop
    @state.verticalScrollbar.scrollTop = scrollTop

    @emitter.emit 'did-update-state'

  updateHorizontalScrollState: ->
    scrollWidth = @computeScrollWidth()
    @state.content.scrollWidth = scrollWidth
    @state.horizontalScrollbar.scrollWidth = scrollWidth

    scrollLeft = @computeScrollLeft()
    @state.content.scrollLeft = scrollLeft
    @state.horizontalScrollbar.scrollLeft = scrollLeft

    @emitter.emit 'did-update-state'

  updateScrollbarsState: ->
    horizontalScrollbarHeight = @computeHorizontalScrollbarHeight()
    verticalScrollbarWidth = @computeVerticalScrollbarWidth()

    @state.horizontalScrollbar.visible = horizontalScrollbarHeight > 0
    @state.horizontalScrollbar.height = @horizontalScrollbarHeight
    @state.horizontalScrollbar.right = verticalScrollbarWidth

    @state.verticalScrollbar.visible = verticalScrollbarWidth > 0
    @state.verticalScrollbar.width = @verticalScrollbarWidth
    @state.verticalScrollbar.bottom = horizontalScrollbarHeight

    @emitter.emit 'did-update-state'

  updateContentState: ->
    @state.content.scrollWidth = @computeScrollWidth()
    @state.content.scrollLeft = @scrollLeft
    @state.content.indentGuidesVisible = not @model.isMini() and atom.config.get('editor.showIndentGuide', scope: @model.getRootScopeDescriptor())
    @state.content.backgroundColor = if @model.isMini() then null else @backgroundColor
    @state.content.placeholderText = if @model.isEmpty() then @model.getPlaceholderText() else null
    @emitter.emit 'did-update-state'

  updateLinesState: ->
    return unless @hasRequiredMeasurements()

    visibleLineIds = {}
    startRow = @computeStartRow()
    endRow = @computeEndRow()
    row = startRow
    while row < endRow
      line = @model.tokenizedLineForScreenRow(row)
      visibleLineIds[line.id] = true
      if @state.content.lines.hasOwnProperty(line.id)
        @updateLineState(row, line)
      else
        @buildLineState(row, line)
      row++

    if @mouseWheelScreenRow?
      preservedLine = @model.tokenizedLineForScreenRow(@mouseWheelScreenRow)
      visibleLineIds[preservedLine.id] = true

    for id, line of @state.content.lines
      unless visibleLineIds.hasOwnProperty(id)
        delete @state.content.lines[id]

    @emitter.emit 'did-update-state'

  updateLineState: (row, line) ->
    lineState = @state.content.lines[line.id]
    lineState.screenRow = row
    lineState.top = row * @lineHeight
    lineState.decorationClasses = @lineDecorationClassesForRow(row)

  buildLineState: (row, line) ->
    @state.content.lines[line.id] =
      screenRow: row
      text: line.text
      tokens: line.tokens
      isOnlyWhitespace: line.isOnlyWhitespace()
      endOfLineInvisibles: line.endOfLineInvisibles
      indentLevel: line.indentLevel
      tabLength: line.tabLength
      fold: line.fold
      top: row * @lineHeight
      decorationClasses: @lineDecorationClassesForRow(row)

  updateCursorsState: ->
    @state.content.cursors = {}
    return unless @hasRequiredMeasurements()

    startRow = @computeStartRow()
    endRow = @computeEndRow()

    for cursor in @model.getCursors()
      if cursor.isVisible() and startRow <= cursor.getScreenRow() < endRow
        pixelRect = @pixelRectForScreenRange(cursor.getScreenRange())
        pixelRect.width = @baseCharacterWidth if pixelRect.width is 0
        @state.content.cursors[cursor.id] = pixelRect

    @emitter.emit 'did-update-state'

  updateOverlaysState: ->
    return unless @hasRequiredMeasurements()

    visibleDecorationIds = {}

    for decoration in @model.getOverlayDecorations()
      continue unless decoration.getMarker().isValid()

      {item, position} = decoration.getProperties()
      if position is 'tail'
        screenPosition = decoration.getMarker().getTailScreenPosition()
      else
        screenPosition = decoration.getMarker().getHeadScreenPosition()

      @state.content.overlays[decoration.id] ?= {item}
      @state.content.overlays[decoration.id].pixelPosition = @pixelPositionForScreenPosition(screenPosition)
      visibleDecorationIds[decoration.id] = true

    for id of @state.content.overlays
      delete @state.content.overlays[id] unless visibleDecorationIds[id]

    @emitter.emit "did-update-state"

  updateGutterState: ->
    @state.gutter.maxLineNumberDigits = @model.getLineCount().toString().length
    @state.gutter.backgroundColor = if @gutterBackgroundColor isnt "rgba(0, 0, 0, 0)"
      @gutterBackgroundColor
    else
      @backgroundColor
    @emitter.emit "did-update-state"

  updateLineNumbersState: ->
    startRow = @computeStartRow()
    endRow = @computeEndRow()
    visibleLineNumberIds = {}

    if startRow > 0
      rowBeforeStartRow = startRow - 1
      lastBufferRow = @model.bufferRowForScreenRow(rowBeforeStartRow)
      wrapCount = rowBeforeStartRow - @model.screenRowForBufferRow(lastBufferRow)
    else
      lastBufferRow = null
      wrapCount = 0

    for bufferRow, i in @model.bufferRowsForScreenRows(startRow, endRow - 1)
      if bufferRow is lastBufferRow
        wrapCount++
        id = bufferRow + '-' + wrapCount
        softWrapped = true
      else
        id = bufferRow
        wrapCount = 0
        lastBufferRow = bufferRow
        softWrapped = false

      screenRow = startRow + i
      top = screenRow * @lineHeight
      decorationClasses = @lineNumberDecorationClassesForRow(screenRow)
      foldable = @model.isFoldableAtScreenRow(screenRow)

      @state.gutter.lineNumbers[id] = {screenRow, bufferRow, softWrapped, top, decorationClasses, foldable}
      visibleLineNumberIds[id] = true

    if @mouseWheelScreenRow?
      bufferRow = @model.bufferRowForScreenRow(@mouseWheelScreenRow)
      wrapCount = @mouseWheelScreenRow - @model.screenRowForBufferRow(bufferRow)
      id = bufferRow
      id += '-' + wrapCount if wrapCount > 0
      visibleLineNumberIds[id] = true

    for id of @state.gutter.lineNumbers
      delete @state.gutter.lineNumbers[id] unless visibleLineNumberIds[id]

    @emitter.emit 'did-update-state'

  buildHighlightRegions: (screenRange) ->
    lineHeightInPixels = @lineHeight
    startPixelPosition = @pixelPositionForScreenPosition(screenRange.start, true)
    endPixelPosition = @pixelPositionForScreenPosition(screenRange.end, true)
    spannedRows = screenRange.end.row - screenRange.start.row + 1

    if spannedRows is 1
      [
        top: startPixelPosition.top
        height: lineHeightInPixels
        left: startPixelPosition.left
        width: endPixelPosition.left - startPixelPosition.left
      ]
    else
      regions = []

      # First row, extending from selection start to the right side of screen
      regions.push(
        top: startPixelPosition.top
        left: startPixelPosition.left
        height: lineHeightInPixels
        right: 0
      )

      # Middle rows, extending from left side to right side of screen
      if spannedRows > 2
        regions.push(
          top: startPixelPosition.top + lineHeightInPixels
          height: endPixelPosition.top - startPixelPosition.top - lineHeightInPixels
          left: 0
          right: 0
        )

      # Last row, extending from left side of screen to selection end
      if screenRange.end.column > 0
        regions.push(
          top: endPixelPosition.top
          height: lineHeightInPixels
          left: 0
          width: endPixelPosition.left
        )

      regions

  computeStartRow: ->
    startRow = Math.floor(@computeScrollTop() / @lineHeight) - @lineOverdrawMargin
    Math.max(0, startRow)

  computeEndRow: ->
    startRow = Math.floor(@computeScrollTop() / @lineHeight)
    visibleLinesCount = Math.ceil(@getHeight() / @lineHeight) + 1
    endRow = startRow + visibleLinesCount + @lineOverdrawMargin
    Math.min(@model.getScreenLineCount(), endRow)

  computeScrollWidth: ->
    Math.max(@computeContentWidth(), @contentFrameWidth)

  computeScrollHeight: ->
    Math.max(@computeContentHeight(), @getHeight())

  computeContentWidth: ->
    contentWidth = @pixelPositionForScreenPosition([@model.getLongestScreenRow(), Infinity]).left
    contentWidth += 1 unless @model.isSoftWrapped() # account for cursor width
    contentWidth

  computeContentHeight: ->
    @lineHeight * @model.getScreenLineCount()

  computeClientHeight: ->
    @getHeight() - @computeHorizontalScrollbarHeight()

  computeClientWidth: ->
    @contentFrameWidth - @computeVerticalScrollbarWidth()

  computeScrollTop: ->
    if @hasRequiredMeasurements()
      @scrollTop = Math.min(@scrollTop, @computeScrollHeight() - @computeClientHeight())
    else
      @scrollTop

  computeScrollLeft: ->
    if @hasRequiredMeasurements()
      @scrollLeft = Math.min(@scrollLeft, @computeScrollWidth() - @computeClientWidth())
    else
      @scrollLeft

  computeHorizontalScrollbarHeight: ->
    contentWidth = @computeContentWidth()
    contentHeight = @computeContentHeight()
    clientWidthWithoutVerticalScrollbar = @contentFrameWidth
    clientWidthWithVerticalScrollbar = clientWidthWithoutVerticalScrollbar - @verticalScrollbarWidth
    clientHeightWithoutHorizontalScrollbar = @getHeight()
    clientHeightWithHorizontalScrollbar = clientHeightWithoutHorizontalScrollbar - @horizontalScrollbarHeight

    horizontalScrollbarVisible =
      contentWidth > clientWidthWithoutVerticalScrollbar or
        contentWidth > clientWidthWithVerticalScrollbar and contentHeight > clientHeightWithoutHorizontalScrollbar

    if horizontalScrollbarVisible
      @horizontalScrollbarHeight
    else
      0

  computeVerticalScrollbarWidth: ->
    contentWidth = @computeContentWidth()
    contentHeight = @computeContentHeight()
    clientWidthWithoutVerticalScrollbar = @contentFrameWidth
    clientWidthWithVerticalScrollbar = clientWidthWithoutVerticalScrollbar - @verticalScrollbarWidth
    clientHeightWithoutHorizontalScrollbar = @getHeight()
    clientHeightWithHorizontalScrollbar = clientHeightWithoutHorizontalScrollbar - @horizontalScrollbarHeight

    verticalScrollbarVisible =
      contentHeight > clientHeightWithoutHorizontalScrollbar or
        contentHeight > clientHeightWithHorizontalScrollbar and contentWidth > clientWidthWithoutVerticalScrollbar

    if verticalScrollbarVisible
      @verticalScrollbarWidth
    else
      0

  lineDecorationClassesForRow: (row) ->
    return null if @model.isMini()

    decorationClasses = null
    for id, decoration of @lineDecorationsByScreenRow[row]
      decorationClasses ?= []
      decorationClasses.push(decoration.getProperties().class)
    decorationClasses

  lineNumberDecorationClassesForRow: (row) ->
    return null if @model.isMini()

    decorationClasses = null
    for id, decoration of @lineNumberDecorationsByScreenRow[row]
      decorationClasses ?= []
      decorationClasses.push(decoration.getProperties().class)
    decorationClasses

  getCursorBlinkPeriod: -> @cursorBlinkPeriod

  getCursorBlinkResumeDelay: -> @cursorBlinkResumeDelay

  hasRequiredMeasurements: ->
    @lineHeight? and @baseCharacterWidth? and @getHeight()? and @scrollTop? and @contentFrameWidth? and @scrollLeft?

  setScrollTop: (scrollTop) ->
    unless @scrollTop is scrollTop
      @scrollTop = scrollTop
      @didStartScrolling()
      @updateVerticalScrollState()
      @updateDecorations()
      @updateLinesState()
      @updateCursorsState()
      @updateLineNumbersState()

  didStartScrolling: ->
    if @stoppedScrollingTimeoutId?
      clearTimeout(@stoppedScrollingTimeoutId)
      @stoppedScrollingTimeoutId = null
    @stoppedScrollingTimeoutId = setTimeout(@didStopScrolling.bind(this), @stoppedScrollingDelay)
    @state.content.scrollingVertically = true
    @emitter.emit 'did-update-state'

  didStopScrolling: ->
    @state.content.scrollingVertically = false
    if @mouseWheelScreenRow?
      @mouseWheelScreenRow = null
      @updateLinesState()
      @updateLineNumbersState()
    else
      @emitter.emit 'did-update-state'

  setScrollLeft: (scrollLeft) ->
    unless @scrollLeft is scrollLeft
      @scrollLeft = scrollLeft
      @updateHorizontalScrollState()

  setHorizontalScrollbarHeight: (horizontalScrollbarHeight) ->
    unless @horizontalScrollbarHeight is horizontalScrollbarHeight
      @horizontalScrollbarHeight = horizontalScrollbarHeight
      @updateScrollbarsState()
      @updateVerticalScrollState()

  setVerticalScrollbarWidth: (verticalScrollbarWidth) ->
    unless @verticalScrollbarWidth is verticalScrollbarWidth
      @verticalScrollbarWidth = verticalScrollbarWidth
      @updateScrollbarsState()
      @updateHorizontalScrollState()

  setAutoHeight: (autoHeight) ->
    unless @autoHeight is autoHeight
      @autoHeight = autoHeight
      @updateHeightState()

  setHeight: (height) ->
    unless @height is height
      @height = height
      @updateVerticalScrollState()
      @updateScrollbarsState()
      @updateDecorations()
      @updateLinesState()
      @updateCursorsState()
      @updateLineNumbersState()

  getHeight: ->
    @height ? @computeContentHeight()

  setContentFrameWidth: (contentFrameWidth) ->
    unless @contentFrameWidth is contentFrameWidth
      @contentFrameWidth = contentFrameWidth
      @updateHorizontalScrollState()
      @updateScrollbarsState()
      @updateContentState()
      @updateDecorations()
      @updateLinesState()

  setBackgroundColor: (backgroundColor) ->
    unless @backgroundColor is backgroundColor
      @backgroundColor = backgroundColor
      @updateContentState()

  setGutterBackgroundColor: (gutterBackgroundColor) ->
    unless @gutterBackgroundColor is gutterBackgroundColor
      @gutterBackgroundColor = gutterBackgroundColor
      @updateGutterState()

  setLineHeight: (lineHeight) ->
    unless @lineHeight is lineHeight
      @lineHeight = lineHeight
      @updateHeightState()
      @updateVerticalScrollState()
      @updateDecorations()
      @updateLinesState()
      @updateCursorsState()
      @updateLineNumbersState()
      @updateOverlaysState()

  setMouseWheelScreenRow: (mouseWheelScreenRow) ->
    unless @mouseWheelScreenRow is mouseWheelScreenRow
      @mouseWheelScreenRow = mouseWheelScreenRow
      @didStartScrolling()

  setBaseCharacterWidth: (baseCharacterWidth) ->
    unless @baseCharacterWidth is baseCharacterWidth
      @baseCharacterWidth = baseCharacterWidth
      @characterWidthsChanged()

  getScopedCharWidth: (scopeNames, char) ->
    @getScopedCharWidths(scopeNames)[char]

  getScopedCharWidths: (scopeNames) ->
    scope = @charWidthsByScope
    for scopeName in scopeNames
      scope[scopeName] ?= {}
      scope = scope[scopeName]
    scope.charWidths ?= {}
    scope.charWidths

  batchCharacterMeasurement: (fn) ->
    oldChangeCount = @scopedCharacterWidthsChangeCount
    @batchingCharacterMeasurement = true
    fn()
    @batchingCharacterMeasurement = false
    @characterWidthsChanged() if oldChangeCount isnt @scopedCharacterWidthsChangeCount

  setScopedCharWidth: (scopeNames, char, width) ->
    @getScopedCharWidths(scopeNames)[char] = width
    @scopedCharacterWidthsChangeCount++
    @characterWidthsChanged() unless @batchingCharacterMeasurement

  characterWidthsChanged: ->
    @updateHorizontalScrollState()
    @updateContentState()
    @updateDecorations()
    @updateLinesState()
    @updateCursorsState()
    @updateOverlaysState()

  clearScopedCharWidths: ->
    @charWidthsByScope = {}

  pixelPositionForScreenPosition: (screenPosition, clip=true) ->
    screenPosition = Point.fromObject(screenPosition)
    screenPosition = @model.clipScreenPosition(screenPosition) if clip

    targetRow = screenPosition.row
    targetColumn = screenPosition.column
    baseCharacterWidth = @baseCharacterWidth

    top = targetRow * @lineHeight
    left = 0
    column = 0
    for token in @model.tokenizedLineForScreenRow(targetRow).tokens
      charWidths = @getScopedCharWidths(token.scopes)

      valueIndex = 0
      while valueIndex < token.value.length
        if token.hasPairedCharacter
          char = token.value.substr(valueIndex, 2)
          charLength = 2
          valueIndex += 2
        else
          char = token.value[valueIndex]
          charLength = 1
          valueIndex++

        return {top, left} if column is targetColumn

        left += charWidths[char] ? baseCharacterWidth unless char is '\0'
        column += charLength
    {top, left}

  pixelRectForScreenRange: (screenRange) ->
    if screenRange.end.row > screenRange.start.row
      top = @pixelPositionForScreenPosition(screenRange.start).top
      left = 0
      height = (screenRange.end.row - screenRange.start.row + 1) * @lineHeight
      width = @computeScrollWidth()
    else
      {top, left} = @pixelPositionForScreenPosition(screenRange.start, false)
      height = @lineHeight
      width = @pixelPositionForScreenPosition(screenRange.end, false).left - left

    {top, left, width, height}

  observeDecoration: (decoration) ->
    decorationDisposables = new CompositeDisposable
    decorationDisposables.add decoration.getMarker().onDidChange(@decorationMarkerDidChange.bind(this, decoration))
    if decoration.isType('highlight')
      decorationDisposables.add decoration.onDidChangeProperties(@updateHighlightState.bind(this, decoration))
      decorationDisposables.add decoration.onDidFlash(@highlightDidFlash.bind(this, decoration))
    decorationDisposables.add decoration.onDidDestroy =>
      @disposables.remove(decorationDisposables)
      decorationDisposables.dispose()
      @didDestroyDecoration(decoration)
    @disposables.add(decorationDisposables)

  decorationMarkerDidChange: (decoration, change) ->
    if decoration.isType('line') or decoration.isType('line-number')
      intersectsVisibleRowRange = false
      startRow = @computeStartRow()
      endRow = @computeEndRow()
      oldRange = new Range(change.oldTailScreenPosition, change.oldHeadScreenPosition)
      newRange = new Range(change.newTailScreenPosition, change.newHeadScreenPosition)

      if oldRange.intersectsRowRange(startRow, endRow - 1)
        @removeFromLineDecorationCaches(decoration, oldRange)
        intersectsVisibleRowRange = true

      if newRange.intersectsRowRange(startRow, endRow - 1)
        @addToLineDecorationCaches(decoration, newRange)
        intersectsVisibleRowRange = true

      if intersectsVisibleRowRange
        @updateLinesState() if decoration.isType('line')
        @updateLineNumbersState() if decoration.isType('line-number')

    if decoration.isType('highlight')
      @updateHighlightState(decoration)

    if decoration.isType('overlay')
      @updateOverlaysState()

  didDestroyDecoration: (decoration) ->
    if decoration.isType('line') or decoration.isType('line-number')
      @removeFromLineDecorationCaches(decoration, decoration.getMarker().getScreenRange())
      @updateLinesState() if decoration.isType('line')
      @updateLineNumbersState() if decoration.isType('line-number')
    if decoration.isType('highlight')
      @updateHighlightState(decoration)
    if decoration.isType('overlay')
      @updateOverlaysState()

  highlightDidFlash: (decoration) ->
    flash = decoration.consumeNextFlash()
    if decorationState = @state.content.highlights[decoration.id]
      decorationState.flashCount++
      decorationState.flashClass = flash.class
      decorationState.flashDuration = flash.duration
      @emitter.emit "did-update-state"

  didAddDecoration: (decoration) ->
    @observeDecoration(decoration)

    if decoration.isType('line') or decoration.isType('line-number')
      @addToLineDecorationCaches(decoration, decoration.getMarker().getScreenRange())
      @updateLinesState() if decoration.isType('line')
      @updateLineNumbersState() if decoration.isType('line-number')
    else if decoration.isType('highlight')
      @updateHighlightState(decoration)
    else if decoration.isType('overlay')
      @updateOverlaysState()

  updateDecorations: ->
    @lineDecorationsByScreenRow = {}
    @lineNumberDecorationsByScreenRow = {}
    @highlightDecorationsById = {}

    visibleHighlights = {}
    startRow = @computeStartRow()
    endRow = @computeEndRow()
    return unless 0 <= startRow <= endRow <= Infinity

    for markerId, decorations of @model.decorationsForScreenRowRange(startRow, endRow - 1)
      range = @model.getMarker(markerId).getScreenRange()
      for decoration in decorations
        if decoration.isType('line') or decoration.isType('line-number')
          @addToLineDecorationCaches(decoration, range)
        else if decoration.isType('highlight')
          visibleHighlights[decoration.id] = @updateHighlightState(decoration)

    for id of @state.content.highlights
      unless visibleHighlights[id]
        delete @state.content.highlights[id]

    @emitter.emit 'did-update-state'

  removeFromLineDecorationCaches: (decoration, range) ->
    for row in [range.start.row..range.end.row] by 1
      delete @lineDecorationsByScreenRow[row]?[decoration.id]
      delete @lineNumberDecorationsByScreenRow[row]?[decoration.id]

  addToLineDecorationCaches: (decoration, range) ->
    marker = decoration.getMarker()
    properties = decoration.getProperties()

    return unless marker.isValid()

    if range.isEmpty()
      return if properties.onlyNonEmpty
    else
      return if properties.onlyEmpty
      omitLastRow = range.end.column is 0

    for row in [range.start.row..range.end.row] by 1
      continue if properties.onlyHead and row isnt marker.getHeadScreenPosition().row
      continue if omitLastRow and row is range.end.row

      if decoration.isType('line')
        @lineDecorationsByScreenRow[row] ?= {}
        @lineDecorationsByScreenRow[row][decoration.id] = decoration

      if decoration.isType('line-number')
        @lineNumberDecorationsByScreenRow[row] ?= {}
        @lineNumberDecorationsByScreenRow[row][decoration.id] = decoration

  updateHighlightState: (decoration) ->
    return unless @hasRequiredMeasurements()

    startRow = @computeStartRow()
    endRow = @computeEndRow()
    properties = decoration.getProperties()
    marker = decoration.getMarker()
    range = marker.getScreenRange()

    if decoration.isDestroyed() or not marker.isValid() or range.isEmpty() or not range.intersectsRowRange(startRow, endRow - 1)
      delete @state.content.highlights[decoration.id]
      @emitter.emit 'did-update-state'
      return

    if range.start.row < startRow
      range.start.row = startRow
      range.start.column = 0
    if range.end.row >= endRow
      range.end.row = endRow
      range.end.column = 0

    if range.isEmpty()
      delete @state.content.highlights[decoration.id]
      @emitter.emit 'did-update-state'
      return

    highlightState = @state.content.highlights[decoration.id] ?= {
      flashCount: 0
      flashDuration: null
      flashClass: null
    }
    highlightState.class = properties.class
    highlightState.deprecatedRegionClass = properties.deprecatedRegionClass
    highlightState.regions = @buildHighlightRegions(range)

    @emitter.emit 'did-update-state'
    true

  observeCursor: (cursor) ->
    didChangePositionDisposable = cursor.onDidChangePosition =>
      @pauseCursorBlinking()
      @updateCursorsState()

    didChangeVisibilityDisposable = cursor.onDidChangeVisibility(@updateCursorsState.bind(this))

    didDestroyDisposable = cursor.onDidDestroy =>
      @disposables.remove(didChangePositionDisposable)
      @disposables.remove(didChangeVisibilityDisposable)
      @disposables.remove(didDestroyDisposable)
      @updateCursorsState()

    @disposables.add(didChangePositionDisposable)
    @disposables.add(didChangeVisibilityDisposable)
    @disposables.add(didDestroyDisposable)

  didAddCursor: (cursor) ->
    @observeCursor(cursor)
    @pauseCursorBlinking()
    @updateCursorsState()

  startBlinkingCursors: ->
    @toggleCursorBlinkHandle = setInterval(@toggleCursorBlink.bind(this), @getCursorBlinkPeriod() / 2)

  stopBlinkingCursors: ->
    clearInterval(@toggleCursorBlinkHandle)

  toggleCursorBlink: ->
    @state.content.blinkCursorsOff = not @state.content.blinkCursorsOff
    @emitter.emit 'did-update-state'

  pauseCursorBlinking: ->
    @state.content.blinkCursorsOff = false
    @stopBlinkingCursors()
    @startBlinkingCursorsAfterDelay ?= _.debounce(@startBlinkingCursors, @getCursorBlinkResumeDelay())
    @startBlinkingCursorsAfterDelay()
    @emitter.emit 'did-update-state'

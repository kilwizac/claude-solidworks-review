Attribute VB_Name = "BuildDemoDrawing"
Option Explicit

' =====================================================================
'  BuildDemoDrawing - makes a small demo part and drawing to try
'  "Review with Claude" on (SOLIDWORKS 2025).
'
'  DEMO-100, a 4.00 x 2.00 x 0.25 in mounting plate with four corner
'  holes and a center hole, and a B-size drawing of it (1:1, border and
'  title block, 3 views + isometric) with mistakes
'  planted for the review to find:
'    - the 4.00 length is overridden to show 4.10
'    - only one corner hole is located; the center hole isn't located
'    - the hole callout has no "4X" and no THRU
'    - no material, no DrawnBy / DrawnDate
'    - a note with a spelling mistake
'  Both files are saved next to this macro (DEMO-100.SLDPRT / .SLDDRW)
'  and the drawing is left open, ready for the review macro.
'
'  The drawing itself is made by the AutoDrawing macro when it's found
'  (AUTO_DRAWING_SWP, or automate-drawing\AutoDrawing.swp beside this
'  repo's folder); otherwise a simpler built-in layout is used.
'
'  !!! SolidWorks API lengths are METERS.
' =====================================================================

Private Const IN_TO_M As Double = 0.0254
Private Const PART_NAME As String = "DEMO-100"
Private Const MACRO_TITLE As String = "Build demo drawing"

' Full path to AutoDrawing.swp. Blank = look for
' ..\..\automate-drawing\AutoDrawing.swp next to this repo's folder.
Private Const AUTO_DRAWING_SWP As String = ""

Public Sub Main()
    Dim stepName As String
    Dim swApp As SldWorks.SldWorks
    Dim swPart As SldWorks.ModelDoc2
    Dim swDrawModel As SldWorks.ModelDoc2
    Dim inputDimWas As Boolean
    Dim outDir As String, partPath As String, drawPath As String
    On Error GoTo ErrHandler

    stepName = "connecting to SolidWorks"
    Set swApp = Application.SldWorks
    outDir = ParentFolder(swApp.GetCurrentMacroPathName)
    partPath = outDir & "\" & PART_NAME & ".SLDPRT"
    drawPath = outDir & "\" & PART_NAME & ".SLDDRW"
    ' A rerun rebuilds both files: close earlier copies first.
    CloseIfOpen swApp, drawPath
    CloseIfOpen swApp, partPath

    ' Dimensions added by the API must not pop up the Modify box.
    inputDimWas = swApp.GetUserPreferenceToggle(swInputDimValOnCreate)
    swApp.SetUserPreferenceToggle swInputDimValOnCreate, False

    stepName = "creating the part"
    Set swPart = BuildPart(swApp)

    stepName = "saving the part"
    SaveDoc swPart, partPath

    stepName = "creating the drawing"
    Set swDrawModel = DrawWithAutoDrawing(swApp, swPart, drawPath)
    If swDrawModel Is Nothing Then Set swDrawModel = BuildDrawing(swApp, partPath)

    stepName = "planting the drawing mistakes"
    PlantMistakes swDrawModel

    stepName = "saving the drawing"
    SaveDoc swDrawModel, drawPath

    swApp.SetUserPreferenceToggle swInputDimValOnCreate, inputDimWas
    swApp.CloseDoc swPart.GetTitle
    swApp.ActivateDoc3 swDrawModel.GetTitle, False, 0, 0
    MsgBox "The demo drawing is ready:" & vbCrLf & drawPath & vbCrLf & vbCrLf & _
           "Now run the Review with Claude macro on it.", vbInformation, MACRO_TITLE
    Exit Sub

ErrHandler:
    Dim errNum As Long, errDesc As String
    errNum = Err.Number
    errDesc = Err.Description
    On Error Resume Next
    swApp.SetUserPreferenceToggle swInputDimValOnCreate, inputDimWas
    On Error GoTo 0
    MsgBox MACRO_TITLE & " failed while " & stepName & "." & vbCrLf & vbCrLf & _
           "Error " & CStr(errNum) & ": " & errDesc, vbCritical, MACRO_TITLE
End Sub

' ---------------------------------------------------------------------
' Part: one sketch (plate outline + 5 circles) extruded 0.25 in, so the
' circles become through holes. Sketch dimensions are deliberately
' incomplete - the drawing shows them as they are.
' ---------------------------------------------------------------------
Private Function BuildPart(swApp As SldWorks.SldWorks) As SldWorks.ModelDoc2
    Dim tpl As String, swModel As SldWorks.ModelDoc2
    Dim swSkMgr As SldWorks.SketchManager
    Dim L As Double, W As Double, T As Double, e As Double, rHole As Double, rCenter As Double

    L = 4# * IN_TO_M: W = 2# * IN_TO_M: T = 0.25 * IN_TO_M
    e = 0.375 * IN_TO_M
    rHole = 0.257 / 2# * IN_TO_M
    rCenter = 0.5 / 2# * IN_TO_M

    tpl = swApp.GetUserPreferenceStringValue(swDefaultTemplatePart)
    If Len(tpl) = 0 Then Err.Raise vbObjectError + 1, , "No default part template is set (Tools > Options > Default Templates)."
    Set swModel = swApp.NewDocument(tpl, 0, 0, 0)
    If swModel Is Nothing Then Err.Raise vbObjectError + 2, , "Could not create a part from " & tpl
    swModel.Extension.SetUserPreferenceInteger swUnitSystem, swDetailingNoOptionSpecified, swUnitSystem_IPS

    ' First reference plane = Front (works in any UI language).
    FirstPlane(swModel).Select2 False, 0
    Set swSkMgr = swModel.SketchManager
    swSkMgr.InsertSketch True
    swSkMgr.AddToDB = True

    Dim vRect As Variant, i As Long, swLine As SldWorks.SketchLine
    Dim swBottom As SldWorks.SketchSegment, swLeft As SldWorks.SketchSegment
    vRect = swSkMgr.CreateCornerRectangle(0, 0, 0, L, W, 0)
    For i = LBound(vRect) To UBound(vRect)
        Set swLine = vRect(i)
        If Abs(swLine.GetStartPoint2.Y) < 0.000001 And Abs(swLine.GetEndPoint2.Y) < 0.000001 Then Set swBottom = vRect(i)
        If Abs(swLine.GetStartPoint2.X) < 0.000001 And Abs(swLine.GetEndPoint2.X) < 0.000001 Then Set swLeft = vRect(i)
    Next

    Dim swH1 As SldWorks.SketchSegment, swCenter As SldWorks.SketchSegment
    Set swH1 = swSkMgr.CreateCircleByRadius(e, e, 0, rHole)
    swSkMgr.CreateCircleByRadius L - e, e, 0, rHole
    swSkMgr.CreateCircleByRadius e, W - e, 0, rHole
    swSkMgr.CreateCircleByRadius L - e, W - e, 0, rHole
    Set swCenter = swSkMgr.CreateCircleByRadius(L / 2#, W / 2#, 0, rCenter)
    swSkMgr.AddToDB = False

    ' Length and width
    swModel.ClearSelection2 True
    swBottom.Select4 False, Nothing
    swModel.AddDimension2 L / 2#, -0.4 * IN_TO_M, 0
    swModel.ClearSelection2 True
    swLeft.Select4 False, Nothing
    swModel.AddDimension2 -0.4 * IN_TO_M, W / 2#, 0

    ' One corner hole: size and location. The other three: nothing.
    swModel.ClearSelection2 True
    swH1.Select4 False, Nothing
    swModel.AddDimension2 e + 0.45 * IN_TO_M, e - 0.3 * IN_TO_M, 0
    Dim swArc As SldWorks.SketchArc
    Set swArc = swH1
    swModel.ClearSelection2 True
    swArc.GetCenterPoint2.Select4 False, Nothing
    swLeft.Select4 True, Nothing
    swModel.AddDimension2 e / 2#, W + 0.3 * IN_TO_M, 0
    swModel.ClearSelection2 True
    swArc.GetCenterPoint2.Select4 False, Nothing
    swBottom.Select4 True, Nothing
    swModel.AddDimension2 L + 0.3 * IN_TO_M, e / 2#, 0

    ' Center hole: size only, no location.
    swModel.ClearSelection2 True
    swCenter.Select4 False, Nothing
    swModel.AddDimension2 L / 2# + 0.6 * IN_TO_M, W / 2# + 0.5 * IN_TO_M, 0

    swModel.ClearSelection2 True
    swSkMgr.InsertSketch True

    ' Extrude the sketch 0.25 in.
    swModel.FeatureByPositionReverse(0).Select2 False, 0
    Dim swFeat As SldWorks.Feature
    Set swFeat = swModel.FeatureManager.FeatureExtrusion2(True, False, False, _
        swEndCondBlind, swEndCondBlind, T, 0, False, False, False, False, 0, 0, _
        False, False, False, False, True, True, True, swStartSketchPlane, 0, False)
    If swFeat Is Nothing Then Err.Raise vbObjectError + 3, , "The extrusion failed."
    swModel.ClearSelection2 True
    swModel.ShowNamedView2 "*Isometric", 7
    swModel.ViewZoomtofit2

    ' Title-block properties: some filled, some left blank on purpose.
    Dim cpm As SldWorks.CustomPropertyManager
    Set cpm = swModel.Extension.CustomPropertyManager("")
    cpm.Add3 "PartNumber", swCustomInfoText, PART_NAME, swCustomPropertyReplaceValue
    cpm.Add3 "Description", swCustomInfoText, "MOUNTING PLATE", swCustomPropertyReplaceValue
    cpm.Add3 "Revision", swCustomInfoText, "A", swCustomPropertyReplaceValue

    swModel.ForceRebuild3 False
    Set BuildPart = swModel
End Function

' ---------------------------------------------------------------------
' Drawing: B-size sheet format at 1:1, Front / Top / Right plus an
' isometric, the part's dimensions imported once and auto-arranged, the
' 4.00 length overridden to 4.10, and a misspelled note.
' Sheet coordinates: inches from the bottom-left corner (x IN_TO_M).
' ---------------------------------------------------------------------
Private Function BuildDrawing(swApp As SldWorks.SldWorks, partPath As String) As SldWorks.ModelDoc2
    Dim tpl As String, swModel As SldWorks.ModelDoc2, swDraw As SldWorks.DrawingDoc

    tpl = swApp.GetUserPreferenceStringValue(swDefaultTemplateDrawing)
    If Len(tpl) = 0 Then Err.Raise vbObjectError + 4, , "No default drawing template is set (Tools > Options > Default Templates)."
    Set swModel = swApp.NewDocument(tpl, swDwgPaperBsize, 17# * IN_TO_M, 11# * IN_TO_M)
    If swModel Is Nothing Then Err.Raise vbObjectError + 5, , "Could not create a drawing from " & tpl
    Set swDraw = swModel
    swModel.Extension.SetUserPreferenceInteger swUnitSystem, swDetailingNoOptionSpecified, swUnitSystem_IPS

    ' Border and title block, scale 1:1.
    LoadSheetFormat swApp, swDraw

    ' Third-angle layout: Top above Front, Right beside it, iso top-right.
    ' SOLIDWORKS auto-scales the sheet when the first view goes in, so
    ' the scale is forced back to 1:1 afterwards and every view moved to
    ' its spot (view position = centre of the view, sheet inches).
    Dim vViews(0 To 2) As SldWorks.View, vIso As SldWorks.View
    Set vViews(0) = PlaceView(swDraw, partPath, "*Front", 4.6, 5.6)
    Set vViews(1) = PlaceView(swDraw, partPath, "*Top", 4.6, 7.9)
    Set vViews(2) = PlaceView(swDraw, partPath, "*Right", 8.2, 5.6)
    Set vIso = PlaceView(swDraw, partPath, "*Isometric", 12.6, 7.0)
    swDraw.GetCurrentSheet.SetScale 1, 1, True, True
    swModel.ForceRebuild3 False

    ' The part's dimensions, each shown once, then tidied per view.
    swDraw.InsertModelAnnotations3 swImportModelItemsFromEntireModel, swInsertDimensionsMarkedForDrawing, _
                                   True, True, False, False
    Dim i As Long
    For i = 0 To 2
        ArrangeViewDims swDraw, swModel, vViews(i)
    Next
    ' Auto Arrange leaves diameters alone: put each callout just outside
    ' its hole (front view; model origin is the plate's lower-left corner).
    PlaceDiameters vViews(0)

    swModel.ClearSelection2 True
    swModel.ForceRebuild3 False
    swModel.ViewZoomtofit2
    Set BuildDrawing = swModel
End Function

' Front view at 1:1 is centred on the plate, so a model point (inches
' from the plate's lower-left corner) sits at view centre + (x - 2, y - 1).
Private Sub PlaceDiameters(swView As SldWorks.View)
    Dim vDims As Variant, i As Long, swDisp As SldWorks.DisplayDimension
    Dim vPos As Variant, cx As Double, cy As Double, dia As Double
    On Error Resume Next
    vPos = swView.Position
    cx = vPos(0) / IN_TO_M: cy = vPos(1) / IN_TO_M
    vDims = swView.GetDisplayDimensions
    If Not IsArray(vDims) Then Exit Sub
    For i = LBound(vDims) To UBound(vDims)
        Set swDisp = vDims(i)
        If swDisp.Type2 = swDiameterDimension Then
            dia = swDisp.GetDimension2(0).SystemValue / IN_TO_M
            If Abs(dia - 0.5) < 0.01 Then
                ' Centre hole (2.0, 1.0): callout up and to the right, above the part.
                swDisp.GetAnnotation.SetPosition2 (cx + 0.9) * IN_TO_M, (cy + 1.45) * IN_TO_M, 0
            Else
                ' Corner hole (0.375, 0.375): callout below-left, outside the part.
                swDisp.GetAnnotation.SetPosition2 (cx - 2.35) * IN_TO_M, (cy - 1.45) * IN_TO_M, 0
            End If
        End If
    Next
    On Error GoTo 0
End Sub

' Run AutoDrawing on the (saved, active) part. It saves the drawing as
' <part>.SLDDRW beside the part and leaves it open; Nothing if it isn't
' found or didn't produce the drawing.
Private Function DrawWithAutoDrawing(swApp As SldWorks.SldWorks, swPart As SldWorks.ModelDoc2, _
                                     drawPath As String) As SldWorks.ModelDoc2
    Dim adPath As String, runErr As Long, fso As Object
    Set fso = CreateObject("Scripting.FileSystemObject")
    adPath = AUTO_DRAWING_SWP
    If Len(adPath) = 0 Then
        adPath = fso.BuildPath(fso.GetParentFolderName(fso.GetParentFolderName( _
                 ParentFolder(swApp.GetCurrentMacroPathName))), "automate-drawing\AutoDrawing.swp")
    End If
    If Not fso.FileExists(adPath) Then Exit Function

    ' AutoDrawing asks before overwriting; this drawing is ours to replace.
    If fso.FileExists(drawPath) Then fso.DeleteFile drawPath, True
    swApp.ActivateDoc3 swPart.GetTitle, False, 0, 0
    If swApp.RunMacro2(adPath, "AutoDrawing", "Main", swRunMacroUnloadAfterRun, runErr) <> 0 Then
        Set DrawWithAutoDrawing = swApp.GetOpenDocumentByName(drawPath)
    End If
End Function

' The drawing mistakes the review should find: the 4.00 length overridden
' to show 4.10, and a general note with a spelling mistake ("DEBUR").
Private Sub PlantMistakes(swModel As SldWorks.ModelDoc2)
    Dim swDraw As SldWorks.DrawingDoc, swView As SldWorks.View, vDims As Variant, j As Long
    Dim swDisp As SldWorks.DisplayDimension, done As Boolean
    Set swDraw = swModel
    Set swView = swDraw.GetFirstView
    Do While Not swView Is Nothing And Not done
        vDims = swView.GetDisplayDimensions
        If IsArray(vDims) Then
            For j = LBound(vDims) To UBound(vDims)
                Set swDisp = vDims(j)
                If Abs(swDisp.GetDimension2(0).SystemValue - 4# * IN_TO_M) < 0.00001 Then
                    swDisp.SetOverride True, 4.1 * IN_TO_M
                    done = True
                    Exit For
                End If
            Next
        End If
        Set swView = swView.GetNextView
    Loop

    ' Bottom-left of the sheet, left of the title block and below the views.
    Dim swNote As SldWorks.Note
    swDraw.ActivateSheet swDraw.GetCurrentSheet.GetName
    swModel.ClearSelection2 True
    Set swNote = swModel.InsertNote("NOTES:" & vbCrLf & "1. DEBUR ALL EDGES.")
    If Not swNote Is Nothing Then swNote.GetAnnotation.SetPosition2 0.8 * IN_TO_M, 1.9 * IN_TO_M, 0
    swModel.ClearSelection2 True
    swModel.ForceRebuild3 False
End Sub

Private Function PlaceView(swDraw As SldWorks.DrawingDoc, partPath As String, viewName As String, _
                           xIn As Double, yIn As Double) As SldWorks.View
    Set PlaceView = swDraw.CreateDrawViewFromModelView3(partPath, viewName, xIn * IN_TO_M, yIn * IN_TO_M, 0)
    If PlaceView Is Nothing Then Err.Raise vbObjectError + 6, , "Could not place the " & viewName & " view."
End Function

' Standard "b - landscape" sheet format from the SOLIDWORKS install (or
' the Sheet Formats folder in File Locations), at 1:1. Skipped quietly if
' it can't be found - the drawing still works without a border.
Private Sub LoadSheetFormat(swApp As SldWorks.SldWorks, swDraw As SldWorks.DrawingDoc)
    Dim fso As Object, folders As String, f As Variant, fmtPath As String, cand As String
    Set fso = CreateObject("Scripting.FileSystemObject")
    folders = swApp.GetUserPreferenceStringValue(swFileLocationsSheetFormat)
    folders = Replace(Replace(folders, vbCrLf, ";"), vbLf, ";")
    folders = folders & ";" & fso.GetSpecialFolder(0).Drive & "\ProgramData\SolidWorks\SOLIDWORKS 2025\lang\english\sheetformat"
    For Each f In Split(folders, ";")
        If Len(Trim$(f)) > 0 Then
            cand = Trim$(f) & "\b - landscape.slddrt"
            If fso.FileExists(cand) Then
                fmtPath = cand
                Exit For
            End If
        End If
    Next

    Dim swSheet As SldWorks.Sheet
    Set swSheet = swDraw.GetCurrentSheet
    On Error Resume Next
    If Len(fmtPath) > 0 Then
        swDraw.SetupSheet4 swSheet.GetName, swDwgPaperBsize, swDwgTemplateCustom, 1, 1, False, fmtPath, _
                           17# * IN_TO_M, 11# * IN_TO_M, ""
    End If
    Set swSheet = swDraw.GetCurrentSheet
    swSheet.SetScale 1, 1, True, True
    On Error GoTo 0
End Sub

' Select one view's dimensions and run Auto Arrange on them.
Private Sub ArrangeViewDims(swDraw As SldWorks.DrawingDoc, swModel As SldWorks.ModelDoc2, _
                            swView As SldWorks.View)
    Dim vDims As Variant, i As Long, n As Long
    Dim swSelData As SldWorks.SelectData, swDisp As SldWorks.DisplayDimension
    On Error Resume Next
    vDims = swView.GetDisplayDimensions
    If Not IsArray(vDims) Then Exit Sub
    swDraw.ActivateView swView.Name
    swModel.ClearSelection2 True
    Set swSelData = swModel.SelectionManager.CreateSelectData
    For i = LBound(vDims) To UBound(vDims)
        Set swDisp = vDims(i)
        If swDisp.GetAnnotation.Select3(True, swSelData) Then n = n + 1
    Next
    If n > 0 Then swModel.Extension.AlignDimensions swAlignDimensionType_AutoArrange, 0.375 * IN_TO_M
    swModel.ClearSelection2 True
    On Error GoTo 0
End Sub

' ---------------------------------------------------------------------
' Helpers
' ---------------------------------------------------------------------
Private Function FirstPlane(swModel As SldWorks.ModelDoc2) As SldWorks.Feature
    Dim swFeat As SldWorks.Feature
    Set swFeat = swModel.FirstFeature
    Do While Not swFeat Is Nothing
        If swFeat.GetTypeName2 = "RefPlane" Then
            Set FirstPlane = swFeat
            Exit Function
        End If
        Set swFeat = swFeat.GetNextFeature
    Loop
    Err.Raise vbObjectError + 7, , "The part template has no reference planes."
End Function

Private Sub SaveDoc(swModel As SldWorks.ModelDoc2, filePath As String)
    Dim errs As Long, warns As Long
    If Not (swModel.Extension.SaveAs3(filePath, swSaveAsCurrentVersion, swSaveAsOptions_Silent, _
                                      Nothing, Nothing, errs, warns) <> 0) Then
        Err.Raise vbObjectError + 8, , "Could not save " & filePath & " (error " & errs & ")."
    End If
End Sub

Private Sub CloseIfOpen(swApp As SldWorks.SldWorks, filePath As String)
    Dim swDoc As SldWorks.ModelDoc2
    Set swDoc = swApp.GetOpenDocumentByName(filePath)
    If Not swDoc Is Nothing Then swApp.CloseDoc swDoc.GetTitle
End Sub

Private Function ParentFolder(fullPath As String) As String
    Dim p As Long
    p = InStrRev(fullPath, "\")
    If p > 0 Then ParentFolder = Left$(fullPath, p - 1)
End Function

using UnityEngine;

/// <summary>
/// Static utility class that provides centralized access to common game references.
/// Checks LevelScript and HubScript singletons first, with GameObject.Find fallback.
/// </summary>
public static class GameReferences
{
    // Shared references (exist in both level and hub)
    
    public static GameObject GetPlayer()
    {
        // Check LevelScript first, but verify the GameObject isn't destroyed
        if (LevelScript.Instance != null && LevelScript.Instance.player != null)
            return LevelScript.Instance.player;
        // Check HubScript, verify GameObject isn't destroyed
        if (HubScript.Instance != null && HubScript.Instance.player != null)
            return HubScript.Instance.player;
        // Fallback to Find
        return GameObject.Find("Player");
    }

    public static GameObject GetCanvas()
    {
        if (LevelScript.Instance != null && LevelScript.Instance.canvas != null)
            return LevelScript.Instance.canvas;
        if (HubScript.Instance != null && HubScript.Instance.canvas != null)
            return HubScript.Instance.canvas;
        return GameObject.Find("Canvas");
    }

    public static Transform GetCanvasTransform()
    {
        GameObject canvas = GetCanvas();
        if (canvas != null) return canvas.transform;
        return null;
    }

    public static GameObject GetCharacterUI()
    {
        if (LevelScript.Instance != null && LevelScript.Instance.characterUI != null)
            return LevelScript.Instance.characterUI;
        if (HubScript.Instance != null && HubScript.Instance.characterUI != null)
            return HubScript.Instance.characterUI;
        return GameObject.Find("Character UI");
    }

    public static GameObject GetPlayerHealthBar()
    {
        if (LevelScript.Instance != null && LevelScript.Instance.playerHealthBar != null)
            return LevelScript.Instance.playerHealthBar;
        if (HubScript.Instance != null && HubScript.Instance.playerHealthBar != null)
            return HubScript.Instance.playerHealthBar;
        return GameObject.Find("Player Health Bar");
    }
    
    // Level-only references (return null in hub context)

    public static GameObject GetTurnLogic()
    {
        if (LevelScript.Instance != null && LevelScript.Instance.turnLogic != null)
            return LevelScript.Instance.turnLogic;
        return GameObject.Find("Turn Logic");
    }

    public static TurnLogicScript GetTurnLogicScript()
    {
        if (LevelScript.Instance != null && LevelScript.Instance.turnLogicScript != null)
            return LevelScript.Instance.turnLogicScript;
        GameObject turnLogic = GameObject.Find("Turn Logic");
        if (turnLogic != null) return turnLogic.GetComponent<TurnLogicScript>();
        return null;
    }

    public static GameObject GetEnemies()
    {
        if (LevelScript.Instance != null && LevelScript.Instance.enemies != null)
            return LevelScript.Instance.enemies;
        return GameObject.Find("Enemies");
    }

    public static EnemiesScript GetEnemiesScript()
    {
        if (LevelScript.Instance != null && LevelScript.Instance.enemiesScript != null)
            return LevelScript.Instance.enemiesScript;
        GameObject enemies = GameObject.Find("Enemies");
        if (enemies != null) return enemies.GetComponent<EnemiesScript>();
        return null;
    }

    public static GameObject GetTraversableTiles()
    {
        if (LevelScript.Instance != null && LevelScript.Instance.traversableTiles != null)
            return LevelScript.Instance.traversableTiles;
        return GameObject.Find("Traversable Tiles");
    }

    public static TraversableTilesScript GetTraversableTilesScript()
    {
        if (LevelScript.Instance != null && LevelScript.Instance.traversableTilesScript != null)
            return LevelScript.Instance.traversableTilesScript;
        GameObject tiles = GameObject.Find("Traversable Tiles");
        if (tiles != null) return tiles.GetComponent<TraversableTilesScript>();
        return null;
    }
    
    public static GameObject GetRangeOutline()
    {
        if (LevelScript.Instance != null && LevelScript.Instance.rangeOutline != null)
            return LevelScript.Instance.rangeOutline;
        return GameObject.Find("Range Outline");
    }

    public static GameObject GetSkillsPanel()
    {
        if (LevelScript.Instance != null && LevelScript.Instance.skillsPanel != null)
            return LevelScript.Instance.skillsPanel;
        return GameObject.Find("Skills Panel");
    }

    // Hub-only references (return null in level context)

    public static GameObject GetHubBuilder()
    {
        if (HubScript.Instance != null && HubScript.Instance.hubBuilder != null)
            return HubScript.Instance.hubBuilder;
        return GameObject.Find("Hub Builder");
    }
    
    // Context checks
    
    public static bool IsInLevel()
    {
        return LevelScript.Instance != null;
    }
    
    public static bool IsInHub()
    {
        return HubScript.Instance != null;
    }
}

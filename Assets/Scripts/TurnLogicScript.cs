using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.Controls;
using UnityEngine.EventSystems;
using TMPro;
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;

public class TurnLogicScript : MonoBehaviour
{
    public enum GameState
    {
        BuildingLevel,
        PlayerTurnMove,
        PlayerTurnAttack,
        EnemiesTurn,
    }

    public GameObject player;
    public EntityScript playerScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public GameObject skillsPanel;
    public SkillBarScript skillBarScript;
    public GameObject skipButton;
    public SkipButtonScript skipButtonScript;
    public GameObject attackStepButton;
    public AttackStepButtonScript attackStepButtonScript;
    public GameObject moveStepHighlight;
    public Image moveStepHighlightImage;
    public GameObject attackStepHighlight;
    public Image attackStepHighlightImage;
    public Dictionary<Vector3, GameObject> tileLookup = new Dictionary<Vector3, GameObject>();

    public GameState currentGameState;
    public GameObject skillUsed;
    public bool hasMoved = false;
    public bool overrideSkipAttackStep = false;
    public bool hasAttacked = false;
    public bool turnStarted = false;
    public Coroutine playerMoveCoroutine;
    private bool isPointerOverUI = false;
    public GameObject tileCursor;
    private GameObject mouseDownTile = null;

    IEnumerator WaitForBuildingBeforeNewGameState()
    {
        while (!levelBuilderScript.finishedBuilding)
        {
            yield return null;
        }
        while (!traversableTilesScript.finishedBuilding)
        {
            yield return null;
        }
        while (!skillBarScript.finishedBuilding)
        {
            yield return null;
        }
        while (!playerScript.finishedBuilding)
        {
            yield return null;
        }
        while (!enemiesScript.finishedBuilding)
        {
            yield return null;
        }
        while (!PlayerDataScript.Instance.finishedBuilding)
        {
            yield return null;
        }
        enemiesScript.FillEnemyHealth();
        playerScript.CurrentHealth = playerScript.MaxHealth;
        skillBarScript.UpdateButtons();
        currentGameState = GameState.PlayerTurnMove;
        tileLookup = traversableTilesScript.tileLookup;
    }

    void Start()
    {
        currentGameState = GameState.BuildingLevel;
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<EntityScript>();
        enemies = GameObject.Find("Enemies");
        enemiesScript = enemies.GetComponent<EnemiesScript>();
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        levelBuilder = GameObject.Find("Level Builder");
        levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        skillsPanel = GameObject.Find("Skills Panel");
        skillBarScript = skillsPanel.GetComponent<SkillBarScript>();
        skipButton = GameObject.Find("Skip Button");
        skipButtonScript = skipButton.GetComponent<SkipButtonScript>();
        attackStepButton = GameObject.Find("Attack Step Button");
        attackStepButtonScript = attackStepButton.GetComponent<AttackStepButtonScript>();
        moveStepHighlight = GameObject.Find("Move Step Highlight");
        moveStepHighlightImage = moveStepHighlight.GetComponent<Image>();
        attackStepHighlight = GameObject.Find("Attack Step Highlight");
        attackStepHighlightImage = attackStepHighlight.GetComponent<Image>();
        // wait for LevelBuilder to finish building
        StartCoroutine(WaitForBuildingBeforeNewGameState());
    }


    public IEnumerator PlayerTurnMove()
    {
        hasMoved = false;
        // find reachable tiles
        int playerSpeed = playerScript.Speed;
        Vector3 playerPosition = player.transform.position;
        List<Vector3> reachableTiles = new List<Vector3>();
        for (int i = -playerSpeed; i <= playerSpeed; i++)
        {
            for (int j = -playerSpeed; j <= playerSpeed; j++)
            {
                Vector3 delta = new Vector3(i, j, 0);
                Vector3 reachablePos = playerPosition + delta;
                List<Vector3> shortestPath = traversableTilesScript.ShortestPath(playerPosition, reachablePos);
                // check that tile exists, isn't occupied, and has a path from player
                if (!tileLookup.ContainsKey(reachablePos))
                {
                    continue;
                }
                if (tileLookup[reachablePos].GetComponent<TileScript>().isOccupied)
                {
                    continue;
                }
                if (shortestPath == null)
                {
                    continue;
                }
                if (shortestPath.Count > playerSpeed)
                {
                    continue;
                }
                else
                {
                    reachableTiles.Add(reachablePos);
                }
            }
        }

        foreach (Vector3 pos in reachableTiles)
        {
            TileScript tileScript = tileLookup[pos].GetComponent<TileScript>();
            tileScript.IsHighlighted = true;
        }
        while (!hasMoved)
        {
            yield return null;
        }
        traversableTilesScript.ClearHighlights();
        skillUsed = null;
        currentGameState = GameState.PlayerTurnAttack;
        hasMoved = false;
        turnStarted = false;
        moveStepHighlightImage.enabled = false;
    }

    public void RestartPlayerMoveStep()
    {
        if (currentGameState != GameState.PlayerTurnMove)
        {
            return;
        }
        if (playerMoveCoroutine != null)
        {
            StopCoroutine(playerMoveCoroutine);
            playerMoveCoroutine = null;
        }
        traversableTilesScript.ClearHighlights();
        playerMoveCoroutine = StartCoroutine(PlayerTurnMove());
    }

    IEnumerator PlayerTurnAttack()
    {
        hasAttacked = false;
        while (!hasAttacked)
        {
            yield return null;
        }
        traversableTilesScript.ClearHighlights();
        enemiesScript.KillDeadEnemies();
        PlayerDataScript.Instance.turns += 1;
        MissionLogicScript.Instance.totalTurns += 1;
        currentGameState = GameState.EnemiesTurn;
        hasAttacked = false;
        turnStarted = false;
        attackStepHighlightImage.enabled = false;
    }

    IEnumerator EnemiesTurn()
    {
        traversableTilesScript.ClearHighlights();
        Dictionary<Vector3, GameObject> activeEnemyLookup = new Dictionary<Vector3, GameObject>(enemiesScript.activeEnemyLookup);
        List<GameObject> sortedEnemies = activeEnemyLookup.Values.ToList();
        sortedEnemies.Sort((a, b) =>
        {
            float distA = traversableTilesScript.Distance(player.transform.position, a.transform.position);
            float distB = traversableTilesScript.Distance(player.transform.position, b.transform.position);
            return distA.CompareTo(distB);
        });
        foreach (GameObject enemy in sortedEnemies)
        {
            yield return new WaitForSeconds(0.25f);
            EntityScript enemyScript = enemy.GetComponent<EntityScript>();
            enemyScript.ReduceCooldowns(1);
            enemyScript.ReduceEffectDurations(1);
            enemyScript.ReduceEnchantmentDurations(1);
            enemyScript.DisplayEnchantments();
            if (enemyScript.stunDuration == 0)
            {
                enemiesScript.EnemyTurnMove(enemy);
                yield return new WaitForSeconds(0.25f);
                yield return enemiesScript.EnemyTurnAttack(enemy);
            }
            else
            {
                enemyScript.ReduceStunDuration(1);
            }
            enemyScript.EndOfTurnEnchantmentEffects();
        }
        yield return new WaitForSeconds(0.25f);
        currentGameState = GameState.PlayerTurnMove;
        turnStarted = false;
    }

    void Update()
    {
        if (EventSystem.current.IsPointerOverGameObject())
        {
            isPointerOverUI = true;
        }
        else
        {
            isPointerOverUI = false;
        }
        // to-do - only raycast for cursor once in preparation for the following
        // handle mouse over for tile cursor
        if (Mouse.current != null)
        {
            if (!isPointerOverUI)
            {
                Vector2 mousePosition = Camera.main.ScreenToWorldPoint(Mouse.current.position.ReadValue());
                RaycastHit2D hit = Physics2D.Raycast(mousePosition, Vector2.zero);
                if (hit.collider != null)
                {
                    GameObject tile = hit.collider.gameObject;
                    TileScript tileScript = tile.GetComponent<TileScript>();
                    if (tileScript != null)
                    {
                        if (tileCursor == null)
                        {
                            // create tile cursor
                            tileCursor = new GameObject("Tile Cursor");
                            tileCursor.transform.parent = this.transform.parent; // = level
                            SpriteRenderer tileCursorRenderer = tileCursor.AddComponent<SpriteRenderer>();
                            tileCursorRenderer.sortingOrder = 0;
                            Sprite tileCursorSprite = Resources.Load<Sprite>("TileCursor");
                            tileCursorRenderer.sprite = tileCursorSprite;
                        }
                        if (tileCursor != null)
                        {
                            tileCursor.transform.position = tile.transform.position; 
                            SpriteRenderer tileCursorRenderer = tileCursor.GetComponent<SpriteRenderer>();
                            Color tileCursorColor = tileCursorRenderer.color;
                            if (tileScript.IsHighlighted)
                            {
                                tileCursorColor.a = 1.0f;
                            }
                            else
                            {
                                tileCursorColor.a = 0.125f;
                            }
                            tileCursorRenderer.color = tileCursorColor;
                            tileCursor.SetActive(true);
                        }
                    }
                    else
                    {
                        if (tileCursor != null)
                        {
                            tileCursor.SetActive(false);
                        }
                    }
                }
                else
                {
                    if (tileCursor != null)
                    {
                        tileCursor.SetActive(false);
                    }
                }
            }
        }
        // handle mouse down
        if (Mouse.current != null && Mouse.current.leftButton.wasPressedThisFrame)
        {
            if (!isPointerOverUI)
            {
                Vector2 mousePosition = Camera.main.ScreenToWorldPoint(Mouse.current.position.ReadValue());
                RaycastHit2D hit = Physics2D.Raycast(mousePosition, Vector2.zero);
                if (hit.collider != null)
                {
                    GameObject tile = hit.collider.gameObject;
                    TileScript tileScript = tile.GetComponent<TileScript>();
                    if (tileScript != null)
                    {
                        mouseDownTile = tile;
                    }
                    else
                    {
                        mouseDownTile = null;
                    }
                }
                else
                {
                    mouseDownTile = null;
                }
            }
            else
            {
                mouseDownTile = null;
            }
        }
        // handle mouse up
        if (Mouse.current != null && Mouse.current.leftButton.wasReleasedThisFrame)
        {
            if (!isPointerOverUI && mouseDownTile != null)
            {
                Vector2 mousePosition = Camera.main.ScreenToWorldPoint(Mouse.current.position.ReadValue());
                RaycastHit2D hit = Physics2D.Raycast(mousePosition, Vector2.zero);
                if (hit.collider != null)
                {
                    GameObject tile = hit.collider.gameObject;
                    // only process click if mouse up is on the same tile as mouse down
                    if (tile == mouseDownTile)
                    {
                        TileScript tileScript = tile.GetComponent<TileScript>();
                        if (tileScript != null)
                        {
                            tileScript.OnTileClicked();
                        }
                    }
                }
            }
            mouseDownTile = null;
        }
        // turn logic
        switch (currentGameState)
        {
            case GameState.BuildingLevel:
                break;
            case GameState.PlayerTurnMove:
                if (!hasMoved)
                {
                    if (!turnStarted)
                    {
                        turnStarted = true;
                        // player death
                        if (playerScript.CurrentHealth <= 0)
                        {
                            PlayerDataScript.Instance.deaths += 1;
                            PlayerDataScript.Instance.BuildDataFromPlayer(player);
#if !UNITY_WEBGL || UNITY_EDITOR
                            PlayerDataScript.Instance.SavePlayerData("Autosave");
#endif
                            MissionLogicScript.Instance.MissionDefeat();
                            return;
                        }
                        playerScript.ReduceCooldowns(1);
                        playerScript.ReduceEffectDurations(1);
                        playerScript.ReduceEnchantmentDurations(1);
                        playerScript.DisplayEnchantments();
                        traversableTilesScript.ClearHighlights();
                        moveStepHighlightImage.enabled = true;
                        overrideSkipAttackStep = false;
                        if (playerScript.stunDuration == 0)
                        {
                            playerMoveCoroutine = StartCoroutine(PlayerTurnMove());
                        }
                        else
                        {
                            playerScript.ReduceStunDuration(1);
                            PlayerDataScript.Instance.turns += 1;
                            MissionLogicScript.Instance.totalTurns += 1;
                            currentGameState = GameState.EnemiesTurn;
                            turnStarted = false;
                            moveStepHighlightImage.enabled = false;
                            return;
                        }
                    }
                    Keyboard keyboard = Keyboard.current;
                    if (keyboard != null)
                    {
                        KeyControl[] numberKeys = {
                            keyboard.digit1Key,
                            keyboard.digit2Key,
                            keyboard.digit3Key,
                            keyboard.digit4Key,
                            keyboard.digit5Key,
                            keyboard.digit6Key,
                            keyboard.digit7Key,
                            keyboard.digit8Key
                        };
                        for (int i = 0; i < numberKeys.Length; i++)
                        {
                            if (numberKeys[i].wasPressedThisFrame)
                            {
                                GameObject skillButton = skillBarScript.skillButtons[i];
                                SkillButtonScript skillButtonScript = skillButton.GetComponent<SkillButtonScript>();
                                skillButtonScript.OnActivate();
                            }
                        }
                        if (keyboard.spaceKey.wasPressedThisFrame)
                        {
                            skipButtonScript.OnActivate();
                        }
                    }
                }
                break;
            case GameState.PlayerTurnAttack:
                if (!hasAttacked)
                {
                    if (!turnStarted)
                    {
                        turnStarted = true;
                        traversableTilesScript.ClearHighlights();
                        skillUsed = null;
                        attackStepHighlightImage.enabled = true;
                        if (overrideSkipAttackStep)
                        {
                            StartCoroutine(PlayerTurnAttack());
                        }
                        else
                        {
                            if (enemiesScript.activeEnemyLookup.Count == 0 && PlayerDataScript.Instance.skipAttackStep)
                            {
                                PlayerDataScript.Instance.turns += 1;
                                MissionLogicScript.Instance.totalTurns += 1;
                                currentGameState = GameState.EnemiesTurn;
                                turnStarted = false;
                                attackStepHighlightImage.enabled = false;
                                return;
                            }
                            else
                            {
                                StartCoroutine(PlayerTurnAttack());
                            }
                        }
                    }
                    // check for keypresses
                    Keyboard keyboard = Keyboard.current;
                    if (keyboard != null)
                    {
                        KeyControl[] numberKeys = {
                            keyboard.digit1Key,
                            keyboard.digit2Key,
                            keyboard.digit3Key,
                            keyboard.digit4Key,
                            keyboard.digit5Key,
                            keyboard.digit6Key,
                            keyboard.digit7Key,
                            keyboard.digit8Key
                        };
                        for (int i = 0; i < numberKeys.Length; i++)
                        {
                            if (numberKeys[i].wasPressedThisFrame)
                            {
                                GameObject skillButton = skillBarScript.skillButtons[i];
                                SkillButtonScript skillButtonScript = skillButton.GetComponent<SkillButtonScript>();
                                skillButtonScript.OnActivate();
                            }
                        }
                        // press space to skip attacking
                        if (keyboard.spaceKey.wasPressedThisFrame)
                        {
                            skipButtonScript.OnActivate();
                        }
                    }
                }
                break;
            case GameState.EnemiesTurn:
                if (!turnStarted)
                {
                    turnStarted = true;
                    traversableTilesScript.ClearHighlights();
                    playerScript.EndOfTurnEnchantmentEffects();
                    StartCoroutine(EnemiesTurn());
                }
                break;
        }
    }
}

using UnityEngine;
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
    public TMP_Text turnStatusText;
    public GameObject skillsPanel;
    public SkillBarScript skillBarScript;
    public GameObject skipButton;
    public SkipButtonScript skipButtonScript;
    public Dictionary<Vector3, GameObject> tileLookup = new Dictionary<Vector3, GameObject>();

    public GameState currentGameState;
    private bool isPointerOverUI = false;
    public GameObject skillUsed;
    public bool hasMoved = false;
    public bool hasAttacked = false;
    public bool turnStarted = false;
    public Coroutine playerMoveCoroutine;
    private InputAction clickAction;

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
        turnStatusText = GameObject.Find("Turn Status Text").GetComponent<TMP_Text>();
        skillsPanel = GameObject.Find("Skills Panel");
        skillBarScript = skillsPanel.GetComponent<SkillBarScript>();
        skipButton = GameObject.Find("Skip Button");
        skipButtonScript = skipButton.GetComponent<SkipButtonScript>();
        // subscribe to click action
        var playerInput = FindObjectOfType<PlayerInput>();
        clickAction = playerInput.actions.FindAction("Click");
        clickAction.performed += OnClick;
        // wait for LevelBuilder to finish building
        StartCoroutine(WaitForBuildingBeforeNewGameState());
    }

    void OnDestroy()
    {
        if (clickAction != null)
        {
            clickAction.performed -= OnClick;
        }
    }

    private void OnClick(InputAction.CallbackContext context)
    {
        // don't process clicks if the pointer is over a UI element
        if (isPointerOverUI)
        {
            return;
        }
        Vector2 mousePosition = Camera.main.ScreenToWorldPoint(Mouse.current.position.ReadValue());
        RaycastHit2D hit = Physics2D.Raycast(mousePosition, Vector2.zero);
        if (hit.collider != null)
        {
            TileScript tileScript = hit.collider.GetComponent<TileScript>();
            if (tileScript != null)
            {
                tileScript.OnTileClicked();
            }
        }
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
                            Debug.Log("player died");
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
                        turnStatusText.text = "Player Move Step";
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
                        }
                    }
                    Keyboard keyboard = Keyboard.current;
                    if (keyboard != null)
                    {
                        // press space to skip moving
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
                        turnStatusText.text = "Player Attack Step";
                        StartCoroutine(PlayerTurnAttack());
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
                    turnStatusText.text = "Enemies' turn...";
                    StartCoroutine(EnemiesTurn());
                }
                break;
        }
    }
}

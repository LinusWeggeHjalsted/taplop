using UnityEngine;

public class LevelScript : MonoBehaviour
{
    public static LevelScript Instance { get; private set; }

    // system objects
    public GameObject mainCamera;

    // Core game objects
    public GameObject player;
    public GameObject enemies;
    public GameObject afterimages;
    public GameObject decorations;
    public GameObject traversableTiles;
    public GameObject turnLogic;
    public GameObject levelBuilder;
    public GameObject drops;

    // UI objects
    public GameObject canvas;
    public GameObject characterUI;
    public GameObject skillsPanel;
    public GameObject rangeOutline;
    public GameObject playerHealthBar;
    public GameObject skipButton;
    public GameObject attackStepButton;
    public GameObject moveStepHighlight;
    public GameObject attackStepHighlight;
    public GameObject inventoryButton;
    public GameObject momentumUI;

    // Scripts (cached references)
    public PlayerCharacterScript playerScript;
    public EnemiesScript enemiesScript;
    public TraversableTilesScript traversableTilesScript;
    public TurnLogicScript turnLogicScript;
    public LevelBuilderScript levelBuilderScript;
    public DropsScript dropsScript;

    void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(this.gameObject);
            return;
        }
        Instance = this;

        // Cache all references
        CacheReferences();
    }

    void OnDestroy()
    {
        if (Instance == this)
        {
            Instance = null;
        }
    }

    public void CacheReferences()
    {
        mainCamera = GameObject.Find("Main Camera");

        // Find core game objects
        player = GameObject.Find("Player");
        enemies = GameObject.Find("Enemies");
        afterimages = GameObject.Find("Afterimages");
        decorations = GameObject.Find("Decorations");
        traversableTiles = GameObject.Find("Traversable Tiles");
        turnLogic = GameObject.Find("Turn Logic");
        levelBuilder = GameObject.Find("Level Builder");
        drops = GameObject.Find("Drops");

        // Find UI objects
        canvas = GameObject.Find("Canvas");
        characterUI = GameObject.Find("Character UI");
        skillsPanel = GameObject.Find("Skills Panel");
        rangeOutline = GameObject.Find("Range Outline");
        playerHealthBar = GameObject.Find("Player Health Bar");
        skipButton = GameObject.Find("Skip Button");
        attackStepButton = GameObject.Find("Attack Step Button");
        moveStepHighlight = GameObject.Find("Move Step Highlight");
        attackStepHighlight = GameObject.Find("Attack Step Highlight");
        inventoryButton = GameObject.Find("Inventory Button");
        momentumUI = GameObject.Find("Momentum UI");

        // Cache script references
        if (player != null)
        {
            playerScript = player.GetComponent<PlayerCharacterScript>();
        }
        if (enemies != null)
        {
            enemiesScript = enemies.GetComponent<EnemiesScript>();
        }
        if (traversableTiles != null)
        {
            traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        }
        if (turnLogic != null)
        {
            turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        }
        if (levelBuilder != null)
        {
            levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        }
        if (drops != null)
        {
            dropsScript = drops.GetComponent<DropsScript>();
        }
    }
}

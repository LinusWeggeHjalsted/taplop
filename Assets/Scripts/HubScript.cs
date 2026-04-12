using UnityEngine;

public class HubScript : MonoBehaviour
{
    public static HubScript Instance { get; private set; }

    // Core hub objects
    public GameObject player;
    public GameObject hubBuilder;
    public GameObject hubTiles;
    public GameObject decorations;
    public GameObject hubExits;
    public GameObject mainCamera;

    // Hub colors
    public Color[] hubColors = new Color[6];

    // UI objects (shared with levels)
    public GameObject canvas;
    public GameObject characterUI;
    public GameObject playerHealthBar;

    // Scripts (cached references)
    public HubPlayerScript hubPlayerScript;
    public HubBuilderScript hubBuilderScript;
    public HubTilesScript hubTilesScript;
    public HubExitsScript hubExitsScript;

    void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(this.gameObject);
            return;
        }
        Instance = this;

        // Initialize hub colors (same as mission colors)
        string[] hexColors = new string[6]{
            "#f5f8d4",
            "#d6da7b",
            "#bec761",
            "#aaae56",
            "#969446",
            "#767253"
        };
        for (int i = 0; i < 6; i++)
        {
            Color newColor;
            if (ColorUtility.TryParseHtmlString(hexColors[i], out newColor))
            {
                hubColors[i] = newColor;
            }
            else
            {
                Debug.LogError("invalid hex color");
            }
        }

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

    private void CacheReferences()
    {
        // Find core hub objects
        player = GameObject.Find("Player");
        hubBuilder = GameObject.Find("Hub Builder");
        hubTiles = GameObject.Find("Hub Tiles");
        decorations = GameObject.Find("Decorations");
        hubExits = GameObject.Find("Hub Exits");
        mainCamera = GameObject.Find("Main Camera");

        // Find UI objects
        canvas = GameObject.Find("Canvas");
        characterUI = GameObject.Find("Character UI");
        playerHealthBar = GameObject.Find("Player Health Bar");

        // Cache script references
        if (player != null)
        {
            hubPlayerScript = player.GetComponent<HubPlayerScript>();
        }
        if (hubBuilder != null)
        {
            hubBuilderScript = hubBuilder.GetComponent<HubBuilderScript>();
        }
        if (hubTiles != null)
        {
            hubTilesScript = hubTiles.GetComponent<HubTilesScript>();
        }
        if (hubExits != null)
        {
            hubExitsScript = hubExits.GetComponent<HubExitsScript>();
        }
    }
}

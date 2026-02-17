using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.EventSystems;

public class TileScript : MonoBehaviour
{
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject highlight;
    public SpriteRenderer highlightSpriteRenderer;
    public Sprite[] highlightAnimationSprites = new Sprite[4];
    public bool isOccupied = false;
    private bool isHighlighted = false;
    public bool IsHighlighted
    {
        get
        {
            return this.isHighlighted;
        }
        set
        {
            if (turnLogic == null)
            {
                return;
            }
            // add to highlightedTileLookup when highlighting
            if (value && !this.isHighlighted)
            {
                Vector3 position = this.transform.position;
                traversableTilesScript.highlightedTileLookup.Add(position, this.gameObject);
            }
            // remove from highlightedTileLookup when unhighlighting
            else if (!value && this.isHighlighted)
            {
                Vector3 position = this.transform.position;
                traversableTilesScript.highlightedTileLookup.Remove(position);
            }
            this.isHighlighted = value;
        }
    }
    public float highlightAnimationTimer = 0f;
    public float highlightAnimationInterval = 0.25f;
    public int currentHighlightFrame = 0;
    public bool wasAnimating = false;
    private bool isEnd = false;
    public bool IsEnd
    {
        get
        {
            return isEnd;
        }
        set
        {
            if (value == true)
            {
                GameObject endOverlay = new GameObject("End Overlay");
                endOverlay.transform.parent = this.transform;
                endOverlay.transform.localPosition = new Vector3(0, 0, 0);
                SpriteRenderer endRenderer = endOverlay.AddComponent<SpriteRenderer>();
                endRenderer.sortingOrder = 1;
                Sprite endSprite = Resources.Load<Sprite>("Flag");
                endRenderer.sprite = endSprite;
            }
            isEnd = value;
        }
    }

    void Awake()
    {
        highlight = this.transform.Find("Highlight").gameObject;
        highlightSpriteRenderer = highlight.GetComponent<SpriteRenderer>();
        highlightAnimationSprites = Resources.LoadAll<Sprite>("TileHighlight");
    }

    void Start()
    {
        if (LevelScript.Instance != null)
        {
            player = LevelScript.Instance.player;
            if (player != null) playerScript = player.GetComponent<PlayerCharacterScript>();
            turnLogic = LevelScript.Instance.turnLogic;
            if (turnLogic != null) turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
            traversableTiles = LevelScript.Instance.traversableTiles;
            if (traversableTiles != null) traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        }
    }

    public void OnTileClicked()
    {
        if (!isHighlighted)
        {
            return;
        }
        switch (turnLogicScript.currentGameState)
        {
            case TurnLogicScript.GameState.PlayerTurnMove:
                playerScript.MoveTo(this.transform.position);
                Keyboard keyboard = Keyboard.current;
                if (keyboard.leftCtrlKey.isPressed || keyboard.rightCtrlKey.isPressed)
                {
                    turnLogicScript.overrideSkipAttackStep = true;
                }
                turnLogicScript.didMove = true;
                turnLogicScript.hasMoved = true;
                break;
            case TurnLogicScript.GameState.PlayerTurnAttack:
                GameObject skillUsed = turnLogicScript.skillUsed;
                if (skillUsed == null)
                {
                    // this should never happen I think
                    return;
                }
                SkillScript skillScript = skillUsed.GetComponent<SkillScript>();
                skillScript.UseSkill(this.transform.position, player);
                break;
        }
    }

    void Update()
    {
        if (isHighlighted)
        {
            highlightAnimationTimer += Time.deltaTime;
            if (!wasAnimating)
            {
                wasAnimating = true;
                highlightAnimationTimer = 0;
                highlightSpriteRenderer.enabled = true;
            }
            if (highlightAnimationTimer >= highlightAnimationInterval)
            {
                // step to next animation frame
                currentHighlightFrame = (currentHighlightFrame + 1) % 4;
                highlightSpriteRenderer.sprite = highlightAnimationSprites[currentHighlightFrame];
                highlightAnimationTimer -= highlightAnimationInterval;
            }
        }
        else
        {
            if (wasAnimating)
            {
                wasAnimating = false;
                highlightSpriteRenderer.enabled = false;
            }
        }
    }
}

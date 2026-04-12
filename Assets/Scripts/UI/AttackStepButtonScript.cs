using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using UnityEngine.InputSystem;

public class AttackStepButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler, IPointerDownHandler
{
    public RectTransform buttonRectTransform;
    public Button button;
    public Sprite[] attackStepSprites = new Sprite[2];
    public Image image;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public Transform canvas;
    public GameObject tooltipPrefab;
    public GameObject tooltip;
    private bool wasCtrlHeld = false;

    public void OnPointerDown(PointerEventData eventData)
    {
        SoundControllerScript.Instance.PlayButtonClickDownSound();
    }

    public void OnPointerEnter(PointerEventData eventData)
    {
        Vector3[] buttonCorners = new Vector3[4];
        buttonRectTransform.GetWorldCorners(buttonCorners);
        Vector3 buttonTopRightPosition = buttonCorners[2];
        Transform tooltipTransform = canvas.Find("Tooltip");
        if (tooltipTransform != null)
        {
            tooltip = tooltipTransform.gameObject;
        }
        if (tooltip == null)
        {
            tooltip = Instantiate(tooltipPrefab, canvas);
            tooltip.name = "Tooltip";
            tooltip.transform.SetAsLastSibling();
        }
        if (tooltip != null)
        {
            RectTransform tooltipRectTransform = tooltip.GetComponent<RectTransform>();
            tooltipRectTransform.pivot = new Vector2(1f, 0);
            tooltipRectTransform.position = buttonTopRightPosition;
            TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
            if (enemiesScript.activeEnemyLookup.Count == 0)
            {
                StartCoroutine(tooltipScript.SetText("Toggle Autoskip Attack Step", ""));
            }
            else
            {
                StartCoroutine(tooltipScript.SetText("Attack Step", ""));
            }
        }
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        if (tooltip != null)
        {
            tooltip.SetActive(false);
        }
    }

    public void ForceEnabledInCombat()
    {
        image.sprite = attackStepSprites[0];
    }

    public void DisplayCurrentToggle()
    {
        if (PlayerDataScript.Instance.skipAttackStep)
        {
            image.sprite = attackStepSprites[1];
        }
        else
        {
            image.sprite = attackStepSprites[0];
        }
    }

    public void ToggleSkipAttackStep()
    {
        if (PlayerDataScript.Instance.skipAttackStep)
        {
            PlayerDataScript.Instance.skipAttackStep = false;
            image.sprite = attackStepSprites[0];
        }
        else
        {
            PlayerDataScript.Instance.skipAttackStep = true;
            image.sprite = attackStepSprites[1];
        }
    }

    public void OnActivate()
    {
        if (enemies == null)
        {
            enemies = GameReferences.GetEnemies();
            enemiesScript = enemies.GetComponent<EnemiesScript>();
        }
        if (enemiesScript != null)
        {
            if (enemiesScript.activeEnemyLookup.Count > 0)
            {
                return;
            }
            else
            {
                SoundControllerScript.Instance.PlayButtonClickUpSound();
                ToggleSkipAttackStep();
            }
        }
    }

    void Awake()
    {
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        attackStepSprites = Resources.LoadAll<Sprite>("AttackStep");
        image = this.GetComponent<Image>();
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
    }

    void Start()
    {
        canvas = GameReferences.GetCanvasTransform();
        enemies = GameReferences.GetEnemies();
        enemiesScript = GameReferences.GetEnemiesScript();
        DisplayCurrentToggle();
    }

    void Update()
    {
        Keyboard keyboard = Keyboard.current;
        if (keyboard == null) return;

        bool ctrlHeld = keyboard.leftCtrlKey.isPressed || keyboard.rightCtrlKey.isPressed;

        // Only update on state change
        if (ctrlHeld && !wasCtrlHeld)
        {
            // Ctrl just pressed - show enabled sprite
            image.sprite = attackStepSprites[0];
        }
        else if (!ctrlHeld && wasCtrlHeld)
        {
            // Ctrl just released - restore appropriate state
            if (enemiesScript != null && enemiesScript.activeEnemyLookup.Count > 0)
            {
                // In combat - force enabled sprite
                image.sprite = attackStepSprites[0];
            }
            else
            {
                // Not in combat - show toggle state
                DisplayCurrentToggle();
            }
        }

        wasCtrlHeld = ctrlHeld;
    }
}

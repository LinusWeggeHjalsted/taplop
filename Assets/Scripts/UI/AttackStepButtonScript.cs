using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class AttackStepButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
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
            StartCoroutine(tooltipScript.SetText("Toggle autoskip attack step", ""));
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
            enemies = GameObject.Find("Enemies");
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
                SoundControllerScript.Instance.PlayButtonClickSound();
                ToggleSkipAttackStep();
            }
        }
    }

    void Start()
    {
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        attackStepSprites = Resources.LoadAll<Sprite>("AttackStep");
        image = this.GetComponent<Image>();
        canvas = GameObject.Find("Canvas").transform;
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
        DisplayCurrentToggle();
    }
}

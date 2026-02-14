using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;
using UnityEngine.EventSystems;
using System.Collections;
using System.Collections.Generic;

public class InventoryButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public RectTransform buttonRectTransform;
    public Button button;
    public Transform canvas;
    public Transform characterUI;
    public GameObject inventoryMenuPrefab;
    public GameObject inventoryMenu;
    public GameObject tooltipPrefab;
    public GameObject tooltip;
    public Queue<Sprite> pickupQueue = new Queue<Sprite>();
    public GameObject pickupNotification;
    public bool isDisplayingPickup = false;

    public void OnPointerEnter(PointerEventData eventData)
    {
        // refresh canvas reference if it was destroyed
        if (canvas == null)
        {
            canvas = GameReferences.GetCanvasTransform();
        }
        Vector3[] buttonCorners = new Vector3[4];
        buttonRectTransform.GetWorldCorners(buttonCorners);
        Vector3 buttonTopLeftPosition = buttonCorners[1];
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
            tooltipRectTransform.pivot = new Vector2(0, 0);
            tooltipRectTransform.position = buttonTopLeftPosition;
            TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
            StartCoroutine(tooltipScript.SetText("Inventory [i]", ""));
        }
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        if (tooltip != null)
        {
            tooltip.SetActive(false);
        }
    }

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayMenuSound();
        if (inventoryMenu == null)
        {
            inventoryMenu = Instantiate(inventoryMenuPrefab, characterUI);
        }
        else
        {
            DestroyImmediate(inventoryMenu);
        }
        if (!CameraControllerScript.Instance.draggedSinceLastCenter)
        {
            CameraControllerScript.Instance.MoveToPlayer();
        }
    }

    public void QueuePickupNotification(Sprite itemSprite)
    {
        pickupQueue.Enqueue(itemSprite);
        if (!isDisplayingPickup)
        {
            StartCoroutine(DisplayPickupNotifications());
        }
    }

    IEnumerator DisplayPickupNotifications()
    {
        isDisplayingPickup = true;
        while (pickupQueue.Count > 0)
        {
            Sprite itemSprite = pickupQueue.Dequeue();
            // create pickup notification
            pickupNotification = new GameObject("Pickup Notification");
            pickupNotification.transform.SetParent(canvas, false);
            pickupNotification.transform.SetAsFirstSibling();
            RectTransform notificationRect = pickupNotification.AddComponent<RectTransform>();
            notificationRect.sizeDelta = new Vector2(128f, 128f);
            Canvas canvasComponent = canvas.GetComponent<Canvas>();
            float canvasScale = canvasComponent.scaleFactor;
            notificationRect.position = buttonRectTransform.position + new Vector3(0, buttonRectTransform.rect.height * canvasScale, 0);
            Image notificationImage = pickupNotification.AddComponent<Image>();
            notificationImage.sprite = itemSprite;
            yield return new WaitForSeconds(0.5f);
            Destroy(pickupNotification);
            yield return new WaitForSeconds(0.125f);
        }
        isDisplayingPickup = false;
    }

    void Awake()
    {
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        inventoryMenuPrefab = Resources.Load<GameObject>("Prefabs/UI/Inventory Menu");
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
    }

    void Start()
    {
        canvas = GameReferences.GetCanvasTransform();
        characterUI = GameReferences.GetCharacterUI().transform;
    }

    void Update()
    {
        Keyboard keyboard = Keyboard.current;
        if (keyboard != null)
        {
            if (keyboard.iKey.wasPressedThisFrame)
            {
                OnActivate();
            }
        }
    }
}
